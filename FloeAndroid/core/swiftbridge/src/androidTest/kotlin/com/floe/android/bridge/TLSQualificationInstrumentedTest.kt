// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Installed-device proof for the G02 native TLS / default-trust path
 * (job-b1709c36b200442c). Each probe drives the REAL Android
 * FoundationNetworking trust path (embedded curl + BoringSSL) through the
 * ORIGINAL `StreamingTransport.makeSession` factory and the ORIGINAL
 * provider/MCP adapters against an instrumentation-owned synthetic TLS
 * fixture.
 *
 * Methodology (per Main's ordering): controlled synthetic-chain positives
 * first (test-CA trusted ONLY via the in-test-process
 * URLSessionCertificateAuthorityInfoFile lever, restored in `finally`), the
 * default-system-CA public positive and the unknown-CA negative stay free of
 * any override, and every negative differs from its positive in exactly ONE
 * variable (chain trust, SAN, or expiry) so the typed failure is meaningful.
 * The lever is never present for the public/product probes and the
 * INSECURE_SSL_NO_VERIFY escape is never set.
 *
 * Synthetic fixture material only; no real cloud, no credentials, no user
 * data, no CA-store/clock changes. This is trust-path component evidence,
 * NOT cloud/key/App acceptance and NOT a G02 completion claim.
 */
@RunWith(AndroidJUnit4::class)
class TLSQualificationInstrumentedTest {
    private companion object {
        const val TAG = "FloeQualification"
        const val CANARY = "synthetic-tls-canary-7d1a"
    }

    private val fixtures = mutableListOf<TLSLoopbackFixture>()

    @After
    fun tearDown() {
        fixtures.forEach { it.close() }
        fixtures.clear()
        QualificationNative.nativeTLSClearCABundle()
    }

    private fun newFixture(certAsset: String): TLSLoopbackFixture {
        val fixture = TLSLoopbackFixture(certAsset)
        fixture.start()
        fixtures.add(fixture)
        return fixture
    }

    private fun base(fixture: TLSLoopbackFixture) = "https://127.0.0.1:${fixture.port}"

    private fun assetFile(name: String): String {
        val context = InstrumentationRegistry.getInstrumentation().context
        val target = File(context.filesDir, "tls-qualification/$name")
        target.parentFile?.mkdirs()
        context.assets.open("tls-qualification/$name").use { input ->
            target.outputStream().use { input.copyTo(it) }
        }
        return target.absolutePath
    }

    /** Sets the isolated test-process CA lever, always restoring the default. */
    private fun withCABundle(bundleAsset: String, block: () -> Unit) {
        val path = assetFile(bundleAsset)
        QualificationNative.nativeTLSSetCABundle(path)
        try {
            block()
        } finally {
            QualificationNative.nativeTLSClearCABundle()
            assertNull(
                "CA override lever must be restored after the fixture scenario",
                System.getenv("URLSessionCertificateAuthorityInfoFile"),
            )
        }
    }

    private fun probe(
        scenario: String,
        base: String? = null,
        extra: JSONObject.() -> Unit = {},
    ): JSONObject {
        val spec = JSONObject().put("scenario", scenario)
        base?.let { spec.put("base", it) }
        spec.extra()
        val raw = QualificationNative.nativeTLSQualification(spec.toString())
        Log.i(TAG, "transport-tls $scenario: $raw")
        return JSONObject(raw)
    }

    private fun assertTLSFailure(report: JSONObject, case: String) {
        assertTrue("$case must fail, got $report", report.getBoolean("failed"))
        assertEquals(
            "$case must fail for a TLS-family reason, got $report",
            "tls",
            report.getString("errorFamily"),
        )
        assertTrue(report.getBoolean("rightReason"))
        assertTrue(report.getBoolean("ok"))
    }

    // MARK: - P1 / P2 / P3 deterministic probes

    @Test
    fun p1SystemCADirectoryProbe() {
        val report = probe("p1StoreProbe")
        assertTrue(report.getBoolean("ok"))
        val apex = report.getJSONObject("apex")
        val system = report.getJSONObject("system")
        // At least one candidate store must exist and be populated: a total
        // absence would make every default-trust HTTPS fail closed.
        assertTrue(
            "apex or system CA dir must exist ($report)",
            apex.getBoolean("exists") || system.getBoolean("exists"),
        )
        val selected = report.getString("selectedByFoundation")
        assertTrue(
            "selected dir must be populated ($report)",
            report.getInt("selectedEntryCount") > 0,
        )
        val selectedObject = if (selected == apex.getString("path")) apex else system
        assertTrue("first entry readable ($report)", selectedObject.getBoolean("firstEntryReadable"))
        assertTrue("first entry PEM prefix ($report)", selectedObject.getBoolean("firstEntryPEMPrefix"))
        Log.i(TAG, "transport-tls p1 selected=$selected entries=${report.getInt("selectedEntryCount")}")
        // §6 empty-but-existing apex edge: evidence only, still passes here.
        Log.i(TAG, "transport-tls p1 emptyApexEdge=${report.getBoolean("emptyButExistingSelectedDirEdge")}")
    }

    @Test
    fun p2TrustEnvironmentGuard() {
        val report = probe("p2EnvGuard")
        assertTrue(report.getBoolean("ok"))
        assertFalse(
            "INSECURE_SSL_NO_VERIFY escape must never be set",
            report.getBoolean("insecureEscapeSet"),
        )
        val presence = report.getJSONObject("presence")
        Log.i(TAG, "transport-tls p2 presence=$presence")
    }

    @Test
    fun p3LoadedBinaryIdentity() {
        val report = probe(
            "p3BinaryIdentity",
            extra = { put("expectedAPKSHA256", installedAPKSHA256()) },
        )
        assertTrue(report.getBoolean("ok"))
        assertTrue("mapped APK expected ($report)", report.getBoolean("mapped"))
        assertTrue("mapped APK readable ($report)", report.getBoolean("apkReadable"))
        assertTrue(
            "running mapped APK digest must equal the installed package digest ($report)",
            report.getBoolean("matchesExpected"),
        )
        // Per-library binding (core + FoundationNetworking SDK binary
        // 74b97134...) is closed host-side by native-manifest.py --check and
        // the APK strip-derivative validator; recorded in the lane report.
        Log.i(
            TAG,
            "transport-tls p3 apk=${report.getString("apkSHA256")} pageSize=" +
                "${report.getInt("pageSize")}",
        )
    }

    // MARK: - T1 default-system-trust public positive

    @Test
    fun t1PublicPositiveDefaultTrust() {
        assertNull(
            "no CA override may be present for the public positive",
            System.getenv("URLSessionCertificateAuthorityInfoFile"),
        )
        val report = probe("t1PublicPositive")
        assertTrue("public positive failed: $report", report.getBoolean("ok"))
        val probes = report.getJSONArray("probes")
        for (index in 0 until probes.length()) {
            val item = probes.getJSONObject(index)
            Log.i(
                TAG,
                "transport-tls t1 ${item.getString("url")} status=" +
                    "${item.optInt("status", -1)} matched=${item.optBoolean("statusMatched")}",
            )
        }
    }

    // MARK: - T2 trusted-fixture positive through the provider wrapper

    @Test
    fun t2ProviderOverTrustedFixture() {
        val fixture = newFixture("server-good.p12")
        registerWireSinks(fixture)
        withCABundle("test-ca-bundle.pem") {
            val report = probe(
                "t2ProviderFixture",
                base = base(fixture),
                extra = { put("authCanary", CANARY) },
            )
            assertTrue("provider TLS fixture failed: $report", report.getBoolean("ok"))
            val wires = report.getJSONObject("wires")
            val wirePaths = mapOf(
                "chat" to "/wire-chat/chat/completions",
                "responses" to "/wire-responses/responses",
                "anthropic" to "/wire-anthropic/v1/messages",
            )
            for ((wire, path) in wirePaths) {
                assertTrue("wire $wire", wires.getJSONObject(wire).getBoolean("ok"))
                // The synthetic canary arrived server-side: the wrapper rode
                // the verified TLS connection (header value never leaves the
                // fixture process; equality is asserted, only booleans logged).
                val headers = fixture.headers(path)
                assertNotNull("wire $wire request recorded at $path", headers)
                val expectedHeader = if (wire == "anthropic") "x-api-key" else "authorization"
                assertEquals(
                    "synthetic canary must arrive over the verified TLS wire " +
                        "(recorded headers=${headers?.keys} fixture=${fixture.summary()})",
                    if (wire == "anthropic") CANARY else "Bearer $CANARY",
                    headers?.get(expectedHeader),
                )
            }
        }
    }

    // MARK: - T3..T5 meaningful negatives

    @Test
    fun t3UnknownCAFailsWithoutOverride() {
        val fixture = newFixture("server-unknown.p12")
        val report = probe("t3UnknownCA", base = base(fixture))
        assertTLSFailure(report, "unknown CA")
        assertFalse(report.getBoolean("chainTrustedByLever"))
    }

    @Test
    fun t4WrongSANFailsWithTrustedCA() {
        val fixture = newFixture("server-wrongsan.p12")
        withCABundle("test-ca-bundle.pem") {
            val report = probe("t4WrongSAN", base = base(fixture))
            assertTLSFailure(report, "wrong SAN")
            assertTrue(report.getBoolean("chainTrustedByLever"))
        }
    }

    @Test
    fun t5ExpiredFailsWithTrustedCA() {
        val fixture = newFixture("server-expired.p12")
        withCABundle("test-ca-bundle.pem") {
            val report = probe("t5Expired", base = base(fixture))
            assertTLSFailure(report, "expired")
            assertTrue(report.getBoolean("chainTrustedByLever"))
        }
    }

    // MARK: - T6 override lever: positive leg, then negative leg on a fresh origin

    @Test
    fun t6OverrideLeverProvesCAINFO() {
        // Leg A: trust the UNKNOWN CA through the lever -> the formerly
        // unknown endpoint must verify cleanly (lever works, CAINFO replaces
        // CAPATH).
        val fixtureA = newFixture("server-unknown.p12")
        fixtureA.register("/") { exchange ->
            exchange.headWithLength(200, emptyList(), 2)
            exchange.raw("ok".toByteArray(Charsets.UTF_8))
        }
        withCABundle("unknown-ca-bundle.pem") {
            val positive = probe("t6OverridePositive", base = base(fixtureA))
            assertTrue("override positive leg failed: $positive", positive.getBoolean("ok"))
        }
        // Leg B: lever restored (withCABundle asserted), FRESH fixture origin,
        // same unknown CA -> must fail again (no connection/session reuse).
        val fixtureB = newFixture("server-unknown.p12")
        val negative = probe("t3UnknownCA", base = base(fixtureB))
        assertTLSFailure(negative, "override-cleared unknown CA")
    }

    // MARK: - T7 redirect/auth policy over TLS

    @Test
    fun t7RedirectAndAuthPolicy() {
        val fixture = newFixture("server-good.p12")
        fixture.register("/mcp-redirect") { exchange ->
            exchange.headWithLength(302, listOf("Location" to "/mcp-target"), 0)
        }
        fixture.register("/mcp-target") { exchange ->
            exchange.headWithLength(200, emptyList(), 2)
            exchange.raw("ok".toByteArray(Charsets.UTF_8))
        }
        fixture.register("/redirect-same") { exchange ->
            exchange.headWithLength(302, listOf("Location" to "/target-same"), 0)
        }
        fixture.register("/target-same") { exchange ->
            exchange.headWithLength(200, emptyList(), 2)
            exchange.raw("ok".toByteArray(Charsets.UTF_8))
        }
        fixture.register("/redirect-cross") { exchange ->
            exchange.headWithLength(
                302,
                listOf("Location" to "https://localhost:${fixture.port}/target-cross"),
                0,
            )
        }
        fixture.register("/target-cross") { exchange ->
            exchange.headWithLength(200, emptyList(), 2)
            exchange.raw("ok".toByteArray(Charsets.UTF_8))
        }
        withCABundle("test-ca-bundle.pem") {
            // (a) MCP refuse-redirect: the target must see ZERO requests.
            val mcp = probe("t7MCPRefuseRedirect", base = base(fixture))
            assertEquals(
                "MCP redirect target must receive zero requests (fixture: ${fixture.summary()})",
                0,
                fixture.count("/mcp-target"),
            )
            Log.i(TAG, "transport-tls t7 mcpOutcome=${mcp.optString("redirectOutcome")}")

            // (b) Provider default-follow, same host: canary must survive.
            val same = probe(
                "t7ProviderRedirect",
                base = base(fixture),
                extra = {
                    put("path", "redirect-same")
                    put("authCanary", CANARY)
                },
            )
            assertTrue("same-host redirect must be followed: $same", same.getBoolean("ok"))
            assertEquals(200, same.getInt("status"))
            assertTrue(
                "same-host redirect must land on the target",
                same.getString("finalURL").endsWith("/target-same"),
            )
            val sameHeaders = fixture.headers("/target-same")
            assertEquals(
                "same-host canary forwarding (iOS policy: forwarded)",
                "Bearer $CANARY",
                sameHeaders?.get("authorization"),
            )

            // (c) Provider default-follow, cross host (127.0.0.1 -> localhost,
            // both valid SANs): record the ACTUAL corelibs behavior and
            // compare against the iOS strip-on-cross-host policy.
            val cross = probe(
                "t7ProviderRedirect",
                base = base(fixture),
                extra = {
                    put("path", "redirect-cross")
                    put("authCanary", CANARY)
                },
            )
            assertTrue("cross-host redirect must be followed: $cross", cross.getBoolean("ok"))
            assertEquals(200, cross.getInt("status"))
            assertTrue(
                "cross-host redirect must land on the localhost target",
                cross.getString("finalURL").contains("localhost") &&
                    cross.getString("finalURL").endsWith("/target-cross"),
            )
            val crossHeaders = fixture.headers("/target-cross")
            val crossForwarded = crossHeaders?.get("authorization") == "Bearer $CANARY"
            Log.i(
                TAG,
                "transport-tls t7 crossHostAuthForwarded=$crossForwarded " +
                    "(iOS policy strips on cross-host; fixture count=" +
                    "${fixture.count("/target-cross")})",
            )
            // The iOS-original policy strips the Authorization header on a
            // cross-host redirect. A divergence is a precise current-G02
            // repair scope for Main, never fixed by weakening TLS here.
            assertEquals(
                "cross-host Authorization forwarding must match the original " +
                    "strip-on-cross-host policy (divergence => Main repair scope)",
                false,
                crossForwarded,
            )
        }
    }

    // MARK: - T7b real provider-adapter + collect redirect matrix

    @Test
    fun t7bCollectRedirectPreservesSameOriginHeadersAndStripsCrossOrigin() {
        val fixture = newFixture("server-good.p12")
        fixture.register("/collect-same") { exchange ->
            exchange.headWithLength(302, listOf("Location" to "/collect-same-target"), 0)
        }
        fixture.register("/collect-same-target") { exchange ->
            exchange.headWithLength(200, emptyList(), 2)
            exchange.raw("ok".toByteArray(Charsets.UTF_8))
        }
        fixture.register("/collect-cross") { exchange ->
            exchange.headWithLength(
                302,
                listOf("Location" to "https://localhost:${fixture.port}/collect-cross-target"),
                0,
            )
        }
        fixture.register("/collect-cross-target") { exchange ->
            exchange.headWithLength(200, emptyList(), 2)
            exchange.raw("ok".toByteArray(Charsets.UTF_8))
        }
        withCABundle("test-ca-bundle.pem") {
            val same = probe(
                "t7ProviderRedirect",
                base = base(fixture),
                extra = { put("path", "collect-same"); put("authCanary", CANARY) },
            )
            assertTrue("same-origin collect must follow: $same", same.getBoolean("ok"))
            val sameHeaders = fixture.headers("/collect-same-target")
            assertEquals("Bearer $CANARY", sameHeaders?.get("authorization"))
            assertEquals("synthetic-tls-opaque", sameHeaders?.get("x-provider-custom"))
            assertEquals("application/json", sameHeaders?.get("accept"))

            val cross = probe(
                "t7ProviderRedirect",
                base = base(fixture),
                extra = { put("path", "collect-cross"); put("authCanary", CANARY) },
            )
            assertTrue("cross-host collect must follow: $cross", cross.getBoolean("ok"))
            val crossHeaders = fixture.headers("/collect-cross-target")
            assertNull("cross-host Authorization must be stripped: $crossHeaders",
                crossHeaders?.get("authorization"))
            assertNull("cross-host opaque header must be stripped: $crossHeaders",
                crossHeaders?.get("x-provider-custom"))
            assertEquals("application/json", crossHeaders?.get("accept"))
        }
    }

    @Test
    fun t7cProviderAdapterSameOriginKeepsCanary() {
        val fixture = newFixture("server-good.p12")
        registerWireSinks(fixture)
        fixture.register("/redirect-same-provider/chat/completions") { exchange ->
            exchange.headWithLength(302, listOf("Location" to "/wire-chat/chat/completions"), 0)
        }
        withCABundle("test-ca-bundle.pem") {
            val report = probe(
                "t7ProviderAdapterRedirect",
                base = base(fixture) + "/redirect-same-provider",
                extra = { put("authCanary", CANARY) },
            )
            assertTrue("same-origin provider redirect must complete: $report",
                report.getBoolean("ok"))
            assertEquals("tls-ok", report.getString("text"))
            val headers = fixture.headers("/wire-chat/chat/completions")
            assertEquals("same-origin provider canary must survive Android corelibs",
                "Bearer $CANARY", headers?.get("authorization"))
        }
    }

    @Test
    fun t7dProviderAdapterCrossHostStripsCanary() {
        val fixture = newFixture("server-good.p12")
        registerWireSinks(fixture)
        fixture.register("/redirect-cross-provider/chat/completions") { exchange ->
            exchange.headWithLength(
                302,
                listOf("Location" to "https://localhost:${fixture.port}/wire-chat/chat/completions"),
                0,
            )
        }
        withCABundle("test-ca-bundle.pem") {
            val report = probe(
                "t7ProviderAdapterRedirect",
                base = base(fixture) + "/redirect-cross-provider",
                extra = { put("authCanary", CANARY) },
            )
            assertTrue("cross-host provider redirect must complete: $report",
                report.getBoolean("ok"))
            assertEquals("tls-ok", report.getString("text"))
            val headers = fixture.headers("/wire-chat/chat/completions")
            assertNull("cross-host provider canary must be stripped: $headers",
                headers?.get("authorization"))
        }
    }

    @Test
    fun t7eProviderAdapterCrossPortStripsCanary() {
        val fixture = newFixture("server-good.p12")
        val target = newFixture("server-good.p12")
        target.register("/wire-cross-port/chat/completions") { exchange ->
            sink(exchange, chatSink())
        }
        fixture.register("/redirect-cross-port-provider/chat/completions") { exchange ->
            exchange.headWithLength(
                302,
                listOf("Location" to
                    "https://127.0.0.1:${target.port}/wire-cross-port/chat/completions"),
                0,
            )
        }
        withCABundle("test-ca-bundle.pem") {
            val report = probe(
                "t7ProviderAdapterRedirect",
                base = base(fixture) + "/redirect-cross-port-provider",
                extra = { put("authCanary", CANARY) },
            )
            assertTrue("cross-port provider redirect must complete: $report",
                report.getBoolean("ok"))
            assertEquals("tls-ok", report.getString("text"))
            val headers = target.headers("/wire-cross-port/chat/completions")
            assertNull("cross-port provider canary must be stripped: $headers",
                headers?.get("authorization"))
        }
    }

    @Test
    fun t7fProviderAdapterHTTPSDowngradeIsRefused() {
        val fixture = newFixture("server-good.p12")
        val plain = TransportLoopbackFixture()
        plain.start()
        try {
            plain.register("/downgrade-target") { exchange ->
                exchange.headWithLength(200, emptyList(), 2)
                exchange.raw("ok".toByteArray(Charsets.UTF_8))
            }
            fixture.register("/redirect-downgrade-provider/chat/completions") { exchange ->
                exchange.headWithLength(
                    302,
                    listOf("Location" to
                        "http://127.0.0.1:${plain.port}/downgrade-target"),
                    0,
                )
            }
            withCABundle("test-ca-bundle.pem") {
                val report = probe(
                    "t7ProviderAdapterRedirect",
                    base = base(fixture) + "/redirect-downgrade-provider",
                    extra = { put("authCanary", CANARY) },
                )
                assertEquals(
                    "HTTPS->HTTP must not reach the plain target: $report",
                    0,
                    plain.count("/downgrade-target"),
                )
                assertFalse("downgrade must not complete a provider stream: $report",
                    report.optBoolean("ok") && report.optString("text") == "tls-ok")
            }
        } finally {
            plain.close()
        }
    }

    @Test
    fun t7gProviderAdapterChainAtoBtoADoesNotRestoreCanary() {
        val fixture = newFixture("server-good.p12")
        registerWireSinks(fixture)
        fixture.register("/redirect-chain-provider/chat/completions") { exchange ->
            exchange.headWithLength(
                302,
                listOf("Location" to "https://localhost:${fixture.port}/chain-middle"),
                0,
            )
        }
        fixture.register("/chain-middle") { exchange ->
            exchange.headWithLength(
                302,
                listOf("Location" to
                    "https://127.0.0.1:${fixture.port}/wire-chat/chat/completions"),
                0,
            )
        }
        withCABundle("test-ca-bundle.pem") {
            val report = probe(
                "t7ProviderAdapterRedirect",
                base = base(fixture) + "/redirect-chain-provider",
                extra = { put("authCanary", CANARY) },
            )
            assertTrue("A->B->A provider redirect must complete: $report",
                report.getBoolean("ok"))
            assertEquals("tls-ok", report.getString("text"))
            assertNull("middle hop must not see the canary: ${fixture.headers("/chain-middle")}",
                fixture.headers("/chain-middle")?.get("authorization"))
            assertNull("final A hop must not regain the canary: " +
                "${fixture.headers("/wire-chat/chat/completions")}",
                fixture.headers("/wire-chat/chat/completions")?.get("authorization"))
        }
    }

    // MARK: - T8 NSC non-scope evidence

    @Test
    fun t8NativeIgnoresTestNSC() {
        // Evidence, not a policy change: this androidTest APK pins cleartext
        // to loopback ONLY through floe_transport_test_network.xml. The
        // native T2 success over HTTPS plus the raw-HTTP transport suite
        // together demonstrate on-device that the platform NSC XML does not
        // govern the native curl stack (REPORT F11). Recorded as booleans.
        val fixture = newFixture("server-good.p12")
        registerWireSinks(fixture)
        var tlsWorked = false
        withCABundle("test-ca-bundle.pem") {
            tlsWorked = probe("t2ProviderFixture", base = base(fixture)).getBoolean("ok")
        }
        Log.i(TAG, "transport-tls t8 nativeTLSWorksWithTestNSC=$tlsWorked")
        assertTrue(tlsWorked)
    }

    /**
     * Registers the three scripted wire sinks the ORIGINAL provider adapters
     * POST to, each returning a single text delta ("tls-ok") plus the wire's
     * terminal event — the TLS-qualified analogue of the transport suite's
     * barrier scripts (barrier timing is proven there; here the TLS
     * completion itself is the assertion).
     */
    private fun registerWireSinks(fixture: TLSLoopbackFixture) {
        fixture.register("/wire-chat/chat/completions") { exchange ->
            sink(exchange, chatSink())
        }
        fixture.register("/wire-responses/responses") { exchange ->
            sink(exchange, responsesSink())
        }
        fixture.register("/wire-anthropic/v1/messages") { exchange ->
            sink(exchange, anthropicSink())
        }
    }

    private fun sink(exchange: TLSLoopbackFixture.Exchange, body: String) {
        exchange.headWithLength(200, listOf("Content-Type" to "text/event-stream"), body.length)
        exchange.raw(body.toByteArray(Charsets.UTF_8))
    }

    private fun chatSink() =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"tls-ok\"}}]}\n\n" +
            "data: [DONE]\n\n"

    private fun responsesSink() =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"tls-ok\"}\n\n" +
            "data: [DONE]\n\n"

    private fun anthropicSink() =
        "data: {\"type\":\"content_block_delta\",\"index\":0," +
            "\"delta\":{\"type\":\"text_delta\",\"text\":\"tls-ok\"}}\n\n" +
            "data: [DONE]\n\n"

    /**
     * Hashes the installed package APK itself (read through the target
     * context, no privileged access): with `extractNativeLibs=false` the
     * native P3 report digests the very base.apk the linker mapped into the
     * process, so equality proves the running code is exactly the installed,
     * host-validated artifact. The per-library manifest binding is closed
     * host-side with `native-manifest.py --check` + the strip-derivative
     * validator.
     */
    private fun installedAPKSHA256(): String {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        java.io.FileInputStream(context.packageCodePath).use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
