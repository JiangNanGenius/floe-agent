// SPDX-License-Identifier: MPL-2.0
//
// DEBUG-ONLY product-UID sealed credential enrollment harness (instrumented).
//
// Runs INSIDE the product App process (targetContext is the real product UID
// and the CredentialStore instance is the one the product gateway uses), so
// the AndroidKeyStore key and the imported secret belong to the product App.
//
// Operator flow (all adb commands target the handed device serial):
//   begin:
//     adb -s <serial> shell am instrument -w \
//       -e floeProductEnrollPhase begin \
//       -e floeProviderId <provider-uuid> \
//       -e class com.floe.android.debugcredential.ProductCredentialEnrollmentTest#beginSession \
//       com.floe.agent.full.dev.test/androidx.test.runner.AndroidJUnitRunner
//     -> prints "FLOE_PRODUCT_ENROLL_BEGIN <public descriptor JSON>" (public
//        key + metadata; NO secret material).
//   seal (host, key on protected stdin/fd):
//     python3 FloeAndroid/scripts/seal-debug-credential.py --descriptor <json>
//     (existing sealer; never argv/plaintext)
//   transfer (ciphertext only):
//     adb -s <serial> push sealed.bin /data/local/tmp/floe-sealed.bin
//     adb -s <serial> shell run-as com.floe.agent.full.dev \
//         cp /data/local/tmp/floe-sealed.bin files/floe-sealed.bin
//   import:
//     adb -s <serial> shell am instrument -w \
//       -e floeProductEnrollPhase import \
//       -e floeSealedFile files/floe-sealed.bin \
//       -e floeProviderId <same provider-uuid> \
//       -e class com.floe.android.debugcredential.ProductCredentialEnrollmentTest#importSealed \
//       com.floe.agent.full.dev.test/androidx.test.runner.AndroidJUnitRunner
//     -> prints "FLOE_PRODUCT_ENROLL_IMPORT ok reference=... bytes=...".
//     The vault then resolves provider.<uuid> through the SAME store.
//
// Phase gating is explicit: each method asserts its own phase argument so a
// wrong/omitted phase fails typed instead of silently doing nothing.
package com.floe.android.debugcredential

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class ProductCredentialEnrollmentTest {

    private val context get() = InstrumentationRegistry.getInstrumentation()
        .targetContext

    private fun arg(name: String): String? =
        InstrumentationRegistry.getArguments().getString(name)

    @Test
    fun beginSession() {
        assumeTrue(arg("floeProductEnrollPhase") == "begin")
        val providerId = arg("floeProviderId")
        assertTrue("floeProviderId argument is required", !providerId.isNullOrBlank())
        val json = ProductCredentialEnrollment.begin(context, providerId!!)
        // PUBLIC descriptor only (public key + session metadata).
        Log.i(TAG, "FLOE_PRODUCT_ENROLL_BEGIN $json")
    }

    @Test
    fun importSealed() {
        assumeTrue(arg("floeProductEnrollPhase") == "import")
        val relative = arg("floeSealedFile") ?: "files/floe-sealed.bin"
        val dataDir = context.dataDir
        val file = if (relative.startsWith("/")) {
            File(relative)
        } else {
            // App-private path relative to the data dir (no external storage).
            File(dataDir, relative.removePrefix("files/").let { "files/$it" })
        }
        assertTrue("sealed ciphertext file missing: ${file.absolutePath}",
            file.isFile)
        val result = runBlocking { ProductCredentialEnrollment.import(context, file) }
        assertTrue(result.byteCount > 0)
        assertTrue(result.reference.startsWith("ref:v1:"))
        // When the operator repeats the provider id, assert the EXACT product
        // account binding (the same reference `begin` minted).
        arg("floeProviderId")?.takeIf { it.isNotBlank() }?.let { providerId ->
            assertEquals(
                ProductCredentialEnrollment.opaqueReference(
                    ProductCredentialEnrollment.NAMESPACE,
                    ProductCredentialEnrollment.providerAccount(providerId),
                ),
                result.reference,
            )
        }
        // The ciphertext file is consumed: remove it so no stale blob remains.
        file.delete()
        Log.i(TAG, "FLOE_PRODUCT_ENROLL_IMPORT ok reference=${result.reference} " +
            "bytes=${result.byteCount}")
    }

    @Test
    fun verifyPersisted() {
        assumeTrue(arg("floeProductEnrollPhase") == "verify")
        val providerId = arg("floeProviderId")
        val expected = arg("floeExpectSha256")
        assertTrue("floeProviderId argument is required", !providerId.isNullOrBlank())
        assertTrue("floeExpectSha256 argument is required", !expected.isNullOrBlank())
        val bytes = runBlocking {
            ProductCredentialEnrollment.verify(context, providerId!!, expected!!)
        }
        Log.i(TAG, "FLOE_PRODUCT_ENROLL_VERIFY ok bytes=$bytes")
    }

    /** Product-process readiness readback (public facts only): the REAL
     *  per-domain state incl. transport admission derived from the actual
     *  startup facts on this device. Waits for the generation to install. */
    @Test
    fun productReadiness() {
        assumeTrue(arg("floeProductEnrollPhase") == "readiness")
        // The harness runs INSIDE the product App process: assert the actual
        // UID really is the product UID (not a component/test namespace).
        val uid = android.os.Process.myUid()
        val info = context.packageManager.getApplicationInfo(
            context.packageName, 0)
        assertEquals("must run in the product App UID",
            info.uid, uid)

        val deadline = System.currentTimeMillis() + 25_000
        var json: String? = null
        while (System.currentTimeMillis() < deadline) {
            json = runCatching {
                com.floe.android.bridge.RuntimeCoreNative.g02DomainReadiness()
            }.getOrNull()
            if (json != null) break
            Thread.sleep(250)
        }
        // Reading a JSON blob is NOT readiness: require a real accepted
        // generation + the ordinary domains actually ready.
        assertTrue("readiness readback unavailable (notInstalled)",
            json != null)
        val root = kotlinx.serialization.json.Json
            .parseToJsonElement(json!!) as kotlinx.serialization.json.JsonObject
        val epoch = (root["epoch"] as? kotlinx.serialization.json.JsonPrimitive)
            ?.content?.toLongOrNull() ?: 0L
        val nativeEpoch = (root["nativeRootEpoch"]
            as? kotlinx.serialization.json.JsonPrimitive)?.content?.toLongOrNull() ?: 0L
        assertTrue("accepted generation epoch missing", epoch > 0L)
        assertEquals("native root epoch must equal the generation epoch",
            epoch, nativeEpoch)
        val domains = root["domains"] as? kotlinx.serialization.json.JsonArray
        assertTrue("domain readiness entries missing", domains != null)
        val states = (domains!!).mapNotNull { element ->
            val obj = element as? kotlinx.serialization.json.JsonObject ?: return@mapNotNull null
            val name = (obj["domain"] as? kotlinx.serialization.json.JsonPrimitive)?.content
            val state = (obj["state"] as? kotlinx.serialization.json.JsonPrimitive)?.content
            if (name == null || state == null) null else name to state
        }.toMap()
        for (required in listOf("providerConfigurationDomain",
                                "credentialVaultAdapter", "runDomain",
                                "conversationDomain", "hostAttachmentStaging",
                                "settingsDefaults", "settingsMemory",
                                "settingsPersonalization", "settingsUsage",
                                "skillsMcpDiscovery",
                                "transportDeviceQualification")) {
            assertEquals("$required must be ready", "ready", states[required])
        }
        // Optional domains stay honestly blocked (never fake-ready).
        assertEquals("blocked", states["temporaryDomain"])
        assertEquals("blocked", states["settingsPrivacy"])
        // Logcat truncates long lines: persist the public JSON too.
        val out = File(context.filesDir, "floe-readiness.json")
        out.writeText(json)
        Log.i(TAG, "FLOE_PRODUCT_READINESS ok epoch=$epoch uid=$uid " +
            "file=${out.absolutePath} bytes=${out.length()}")
    }

    /** Confirms the PRODUCT config path bound a provider secret at the exact
     *  canonical account (existence + reference only; never the value). */
    @Test
    fun probeProviderBinding() {
        assumeTrue(arg("floeProductEnrollPhase") == "probe")
        val providerId = arg("floeProviderId")
        assertTrue("floeProviderId argument is required", !providerId.isNullOrBlank())
        val account = ProductCredentialEnrollment.providerAccount(providerId!!)
        val reference = ProductCredentialEnrollment.opaqueReference(
            ProductCredentialEnrollment.NAMESPACE, account)
        val bytes = runBlocking {
            com.floe.android.credentials.AndroidKeystoreCredentialStore.create(
                context.applicationContext ?: context,
                ProductCredentialEnrollment.NAMESPACE).read(reference)
        }
        assertTrue("product credential missing at $account", bytes != null)
        Log.i(TAG, "FLOE_PRODUCT_ENROLL_PROBE ok account=$account " +
            "reference=$reference bytes=${bytes!!.size}")
    }

    @Test
    fun cleanupSynthetic() {
        assumeTrue(arg("floeProductEnrollPhase") == "cleanup")
        val providerId = arg("floeProviderId")
        assertTrue("floeProviderId argument is required", !providerId.isNullOrBlank())
        val deleted = runBlocking {
            ProductCredentialEnrollment.deleteSynthetic(context, providerId!!)
        }
        Log.i(TAG, "FLOE_PRODUCT_ENROLL_CLEANUP deleted=$deleted")
    }

    /** READ-ONLY real provider metadata export through the ACTUAL product
     *  command path (`config.providers.list`). Emits providerId/displayName
     *  and the REAL persisted secret status + opaque reference — never a
     *  secret value, never a fabricated provider row, never a direct DB read.
     *  Main uses it after saving a provider in the UI to get the actual UUID
     *  and verify the logical secretRef binding.
     *
     *  This is a BUSINESS assertion now: the accepted queue receipt must
     *  produce a Completed effect value carrying the frozen OBJECT wrapper
     *  `{"rows":[...]}` whose elements are the real native
     *  `ConfigProviderSummary` objects. A rejected/malformed/empty substitute
     *  fails the test instead of writing a misleading empty file (the rows
     *  themselves are the actual store contents — currently legitimately
     *  empty until Main configures a real provider through the UI). */
    @Test
    fun exportProviderMetadata() {
        assumeTrue(arg("floeProductEnrollPhase") == "providersExport")
        val epoch = awaitAcceptedEpoch()
        val expectedUid = context.packageManager.getApplicationInfo(
            context.packageName, 0).uid
        assertEquals("must run in the product App UID",
            expectedUid, android.os.Process.myUid())
        val client = com.floe.android.host.RuntimeHostCommandClient.system()
        val correlation = "providers-export-${System.nanoTime()}"
        val request = com.floe.android.host.HostCommandRequest(
            command = "config.providers.list",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
            stateful = false,
            correlationID = correlation,
            payload = kotlinx.serialization.json.JsonObject(mapOf(
                "operation" to kotlinx.serialization.json.JsonPrimitive("snapshot"))),
        )
        val result = runBlocking {
            kotlinx.coroutines.withTimeout(25_000) {
                val submitted = client.submit(request)
                check(submitted is com.floe.android.host.HostSubmitResult.Accepted) {
                    "providers_list_rejected: $submitted"
                }
                val done = java.util.concurrent.CountDownLatch(1)
                var terminal: com.floe.android.host.HostEffectTerminal? = null
                var failure: com.floe.android.host.HostPumpFailure? = null
                val handle = client.openEffectStream(
                    operationReceiptID = (submitted as com.floe.android.host.HostSubmitResult.Accepted)
                        .operationReceiptID,
                    configurationScope = "providers",
                    onFrame = { },
                    onTerminal = { value ->
                        terminal = value
                        done.countDown()
                    },
                    onFailure = { value ->
                        failure = value
                        done.countDown()
                    },
                )
                try {
                    check(done.await(20, java.util.concurrent.TimeUnit.SECONDS)) {
                        "providers_list_effect_timeout"
                    }
                } finally {
                    handle.close()
                }
                check(failure == null) { "providers_list_pump_failed: $failure" }
                val completed = terminal as? com.floe.android.host.HostEffectTerminal.Completed
                    ?: throw IllegalStateException("providers_list_not_completed: $terminal")
                completed.value
            }
        }
        // Main decision 2026-10-20: the OBJECT-only effect carrier delivers
        // the provider page as the explicit {"rows":[...]} document composed
        // at the G02 domain-to-carrier binder boundary. Reading exactly that
        // wrapper keeps a bad/old shape visible (never an empty substitute).
        val root = result as? kotlinx.serialization.json.JsonObject
            ?: throw AssertionError("providers_list_value_not_object: $result")
        val rows = root["rows"] as? kotlinx.serialization.json.JsonArray
            ?: throw AssertionError("providers_list_object_missing_rows: $root")
        val exported = kotlinx.serialization.json.JsonArray(rows.map { element ->
            val obj = element as? kotlinx.serialization.json.JsonObject
                ?: throw AssertionError("providers_list_row_not_object")
            fun str(key: String): String? =
                (obj[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
            val id = str("id") ?: throw AssertionError("provider row id missing: $obj")
            java.util.UUID.fromString(id)
            val secret = obj["secret"] as? kotlinx.serialization.json.JsonObject
                ?: throw AssertionError("provider secret status missing: $obj")
            val configured = (secret["configured"]
                as? kotlinx.serialization.json.JsonPrimitive)?.content?.toBoolean() ?: false
            val opaque = (secret["opaqueReference"]
                as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
            if (configured) {
                assertTrue("configured provider must carry an opaque reference: $obj",
                    !opaque.isNullOrBlank() && opaque.startsWith("ref:v1:"))
            }
            kotlinx.serialization.json.JsonObject(mapOf(
                "providerId" to kotlinx.serialization.json.JsonPrimitive(id),
                "displayName" to kotlinx.serialization.json.JsonPrimitive(
                    str("displayName") ?: ""),
                "baseURL" to kotlinx.serialization.json.JsonPrimitive(str("baseURL") ?: ""),
                "enabled" to kotlinx.serialization.json.JsonPrimitive(
                    str("isEnabled") ?: "false"),
                "secretConfigured" to kotlinx.serialization.json.JsonPrimitive(configured),
                "secretOpaqueReference" to kotlinx.serialization.json.JsonPrimitive(
                    opaque ?: ""),
            ))
        })
        // Optional strict expectation for Main's post-save export: when the
        // caller names the provider, the real persisted record MUST be there
        // with a configured secret and the exact canonical account reference.
        arg("floeProviderId")?.takeIf { it.isNotBlank() }?.let { expectedProviderId ->
            val row = exported.firstOrNull {
                ((it as kotlinx.serialization.json.JsonObject)["providerId"]
                    as? kotlinx.serialization.json.JsonPrimitive)?.content == expectedProviderId
            } ?: throw AssertionError("expected provider not present: $expectedProviderId")
            val obj = row as kotlinx.serialization.json.JsonObject
            assertEquals("configured provider secret status",
                "true", (obj["secretConfigured"]
                    as? kotlinx.serialization.json.JsonPrimitive)?.content)
            val expectedReference = ProductCredentialEnrollment.opaqueReference(
                ProductCredentialEnrollment.NAMESPACE,
                ProductCredentialEnrollment.providerAccount(expectedProviderId),
            )
            assertEquals("provider logical secretRef binding",
                expectedReference,
                (obj["secretOpaqueReference"]
                    as? kotlinx.serialization.json.JsonPrimitive)?.content)
        }
        val document = kotlinx.serialization.json.JsonObject(mapOf(
            "epoch" to kotlinx.serialization.json.JsonPrimitive(epoch),
            "productUid" to kotlinx.serialization.json.JsonPrimitive(expectedUid),
            "providers" to exported,
        ))
        val out = File(context.filesDir, "floe-providers.json")
        out.writeText(document.toString())
        Log.i(TAG, "FLOE_PRODUCT_PROVIDERS ok epoch=$epoch uid=$expectedUid " +
            "count=${exported.size} file=${out.absolutePath} bytes=${out.length()}")
    }

    /** Waits for the REAL accepted runtime generation and returns its epoch.
     *  A JSON blob alone is NOT readiness: epoch must be positive and equal
     *  the native root epoch. */
    private fun awaitAcceptedEpoch(): Long {
        val deadline = System.currentTimeMillis() + 30_000
        while (System.currentTimeMillis() < deadline) {
            val raw = runCatching {
                com.floe.android.bridge.RuntimeCoreNative.g02DomainReadiness()
            }.getOrNull()
            if (raw != null) {
                val root = kotlinx.serialization.json.Json
                    .parseToJsonElement(raw) as kotlinx.serialization.json.JsonObject
                fun long(key: String): Long =
                    (root[key] as? kotlinx.serialization.json.JsonPrimitive)
                        ?.content?.toLongOrNull() ?: 0L
                val epoch = long("epoch")
                if (epoch > 0 && long("nativeRootEpoch") == epoch) return epoch
            }
            Thread.sleep(250)
        }
        throw AssertionError("accepted runtime generation not observed")
    }

    /** READ-ONLY raw-wire probe: sends the SAME config.providers.list command
     *  through a recording exchange (the real JNI path), stores the exact
     *  request/response strings, the queue submit result and the effect
     *  terminal value, and ASSERTS the canonical business success
     *  (Accepted + Completed array). A rejected outcome fails this test; it
     *  can no longer be mistaken for a diagnostic-only pass. No secret is
     *  involved in a providers list. */
    @Test
    fun probeProvidersListWire() {
        assumeTrue(arg("floeProductEnrollPhase") == "wireProbe")
        val epoch = awaitAcceptedEpoch()
        val recorder = StringBuilder()
        val exchange = object : com.floe.android.host.HostBridgeExchange {
            override fun exchange(request: String): String {
                val response = com.floe.android.bridge.SwiftCore.exchange(request)
                recorder.append("REQUEST\n").append(request).append("\n")
                recorder.append("RESPONSE\n").append(response).append("\n")
                return response
            }
        }
        val client = com.floe.android.host.RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        )
        val request = com.floe.android.host.HostCommandRequest(
            command = "config.providers.list",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
            stateful = false,
            correlationID = "wire-probe-${System.nanoTime()}",
            payload = kotlinx.serialization.json.JsonObject(mapOf(
                "operation" to kotlinx.serialization.json.JsonPrimitive("snapshot"))),
        )
        val (outcome, terminal) = runBlocking {
            kotlinx.coroutines.withTimeout(25_000) {
                val submitted = client.submit(request)
                if (submitted !is com.floe.android.host.HostSubmitResult.Accepted) {
                    return@withTimeout submitted to null
                }
                val done = java.util.concurrent.CountDownLatch(1)
                var result: com.floe.android.host.HostEffectTerminal? = null
                var failure: com.floe.android.host.HostPumpFailure? = null
                val handle = client.openEffectStream(
                    operationReceiptID = submitted.operationReceiptID,
                    configurationScope = "providers",
                    onFrame = { },
                    onTerminal = {
                        result = it
                        done.countDown()
                    },
                    onFailure = {
                        failure = it
                        done.countDown()
                    },
                )
                try {
                    check(done.await(20, java.util.concurrent.TimeUnit.SECONDS)) {
                        "wire_probe_effect_timeout"
                    }
                } finally {
                    handle.close()
                }
                check(failure == null) { "wire_probe_pump_failed: $failure" }
                submitted to result
            }
        }
        recorder.append("EPOCH\n").append(epoch).append("\n")
        recorder.append("SUBMIT\n").append(outcome.toString()).append("\n")
        recorder.append("TERMINAL\n").append(terminal.toString()).append("\n")
        val out = File(context.filesDir, "floe-wire-probe.txt")
        out.writeText(recorder.toString())
        assertTrue("wire probe was not accepted: $outcome",
            outcome is com.floe.android.host.HostSubmitResult.Accepted)
        val completed = terminal as? com.floe.android.host.HostEffectTerminal.Completed
            ?: throw AssertionError("wire probe did not complete: $terminal")
        val probeRoot = completed.value as? kotlinx.serialization.json.JsonObject
            ?: throw AssertionError("wire probe value is not the {rows} OBJECT: ${completed.value}")
        assertTrue("wire probe object carries no rows array: $probeRoot",
            probeRoot["rows"] is kotlinx.serialization.json.JsonArray)
        Log.i(TAG, "FLOE_PRODUCT_WIRE ok epoch=$epoch submit=$outcome " +
            "file=${out.absolutePath}")
    }

    private companion object {
        const val TAG = "FloeProductEnroll"
    }
}
