// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.bridge.RuntimeNativeException
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM source tests for the RB-1 runtime bootstrap coordinator. They use a
 * scripted fake native facade + fake exchange; no Android runtime, no real
 * native library, no disk, Keystore or device is touched. All wire/status
 * expectations are decoded with the SAME pinned kotlinx-serialization-json
 * library as production (`Json.parseToJsonElement`), never Regex.
 *
 * AUTHORED ONLY: no Gradle/test execution is performed by this source package.
 */
class RuntimeBootstrapCoordinatorTest {
    private class FakeNative : RuntimeNativeApi {
        val events = CopyOnWriteArrayList<String>()
        var loaded = false
        var startResult: String? = "op:v1:" + "0".repeat(32)
        var startStatus: Int? = null          // throws when non-null
        var stopResult: String? = null
        var stopStatus: Int? = null
        var statusJson: String? = statusJson(1)
        val startEpochs = CopyOnWriteArrayList<Long>()
        val startRoots = CopyOnWriteArrayList<String>()
        val startTokens = CopyOnWriteArrayList<String>()
        val stopEpochs = CopyOnWriteArrayList<Long>()
        val stopTokens = CopyOnWriteArrayList<String>()

        override fun ensureLoaded() {
            loaded = true
            events.add("load")
        }

        override fun runtimeOwnerStart(rootPath: String, ownerToken: String, epoch: Long): String {
            events.add("start:$epoch")
            startRoots.add(rootPath)
            startTokens.add(ownerToken)
            startEpochs.add(epoch)
            startStatus?.let { throw RuntimeNativeException(it) }
            return startResult ?: throw IllegalStateException("no_receipt_configured")
        }

        override fun runtimeOwnerStop(ownerEpoch: Long, ownerToken: String): String {
            events.add("stop:$ownerEpoch")
            stopEpochs.add(ownerEpoch)
            stopTokens.add(ownerToken)
            stopStatus?.let { throw RuntimeNativeException(it) }
            return stopResult ?: throw RuntimeNativeException(-207)
        }

        override fun runtimeStatus(): String? {
            events.add("status")
            return statusJson
        }
    }

    private class FakeExchange : RuntimeBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        private val responders = ConcurrentLinkedQueue<(JsonObject) -> String>()
        /** Used when the scripted queue is empty (repeats forever). */
        var repeat: ((JsonObject) -> String)? = null
        var alwaysThrow = false

        fun enqueue(raw: String) {
            responders.add { raw }
        }

        fun enqueue(responder: (JsonObject) -> String) {
            responders.add(responder)
        }

        override fun exchange(request: String): String {
            requests.add(request)
            if (alwaysThrow) throw IllegalStateException("exchange_unavailable")
            val root = Json.parseToJsonElement(request).jsonObject
            responders.poll()?.let { return it(root) }
            return repeat?.invoke(root)
                ?: """{"version":3,"requestID":"${root.requestId()}","ok":false,""" +
                    """"error":"runtimeUnavailable","reason":"effectPumpUnbound"}"""
        }
    }

    private fun coordinator(
        native: FakeNative,
        exchange: FakeExchange,
        gateway: MutableStateFlow<SecretGatewayCapability>,
        rootValue: suspend () -> String = { "/data/user/0/com.floe.android/files/floe-runtime" },
        tokenValue: () -> String = { "0123456789abcdef0123456789abcdef" },
        timings: RuntimeBootstrapTimings = RuntimeBootstrapTimings(
            effectPollIntervalMillis = 1, bootstrapDeadlineMillis = 250,
            shutdownDeadlineMillis = 100),
        scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        ioDispatcher: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Unconfined,
        corpusInstaller: RuntimeSecurityCorpusInstaller? = null,
        diagnostics: (String) -> Unit = {},
    ): RuntimeBootstrapCoordinator = RuntimeBootstrapCoordinator(
        native = native,
        exchange = exchange,
        gatewayCapability = gateway,
        rootProvider = rootValue,
        ownerTokenProvider = tokenValue,
        scope = scope,
        ioDispatcher = ioDispatcher,
        timings = timings,
        diagnostics = diagnostics,
        corpusInstaller = corpusInstaller,
    )

    // MARK: - Structured response builders

    private fun gatewayResponse(requestID: String, registered: Boolean = true): String =
        """{"version":2,"requestID":"$requestID","ok":true,"secretBackend":{""" +
            """"registered":$registered,"availability":"${if (registered) "AVAILABLE" else "NEEDS_CONFIGURATION"}",""" +
            """"memoryFallback":false}}"""

    private fun effectPage(requestID: String, receipt: String, effectsJson: String,
                           sequence: Long, hasMore: Boolean = false,
                           resync: Boolean = false): String =
        """{"version":3,"requestID":"$requestID","ok":true,""" +
            """"schema":"floe.effect-cursor/3","correlationID":"$requestID",""" +
            """"cursor":{"operationReceiptID":"$receipt","sequence":$sequence},""" +
            """"effects":[$effectsJson],"hasMore":$hasMore,"resyncRequired":$resync}"""

    private fun effectPageResponder(effectsJson: String, sequence: Long,
                                    hasMore: Boolean = false,
                                    resync: Boolean = false): (JsonObject) -> String =
        { request ->
            effectPage(request.requestId(), request.effectReceipt(), effectsJson,
                sequence, hasMore, resync)
        }

    private fun acceptedEffectJson(sequence: Long = 1): String =
        """{"sequence":$sequence,"kind":"accepted",""" +
            """"detail":[{"key":"ownedStoreReady","value":"true"}]}"""

    private fun failedEffectJson(code: String, sequence: Long = 1): String =
        """{"sequence":$sequence,"kind":"failed","code":"$code"}"""

    // MARK: - Ordering and gating

    @Test
    fun testNoNativeWorkBeforeGatewayReady() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Loading)
        val subject = coordinator(native, exchange, gateway)
        val job = launch(Dispatchers.Unconfined) { subject.bootstrap() }
        withTimeout(500) {
            while (subject.capability.value !is RuntimeBootstrapCapability.WaitingGateway) {
                kotlinx.coroutines.yield()
            }
        }
        assertFalse(native.loaded)
        assertTrue(exchange.requests.isEmpty())
        assertEquals(RuntimeBootstrapCapability.WaitingGateway, subject.capability.value)
        gateway.value = SecretGatewayCapability.Failed("readback_failed")
        withTimeout(1_000) { job.join() }
        assertTrue(subject.capability.value is RuntimeBootstrapCapability.Failed)
        assertFalse(native.loaded)
    }

    @Test
    fun testGatewayFailedNeverTouchesNative() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        val gateway = MutableStateFlow<SecretGatewayCapability>(
            SecretGatewayCapability.Failed("generation_failure"))
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("gateway_failed"), subject.capability.value)
        assertFalse(native.loaded)
        assertTrue(exchange.requests.isEmpty())
    }

    @Test
    fun testGatewayReadbackRefusalStopsBootstrap() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.repeat = { request -> gatewayResponse(request.requestId(), registered = false) }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("gateway_readback_failed"),
            subject.capability.value)
        assertFalse(native.loaded)
    }

    @Test
    fun testRootFailureNeverCallsNativeStart() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.repeat = { request -> gatewayResponse(request.requestId()) }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway, rootValue = {
            throw java.io.IOException("runtime_root_unavailable")
        })
        subject.bootstrap()
        assertEquals(RuntimeBootstrapCapability.Failed("root_unavailable"), subject.capability.value)
        assertFalse(native.events.contains("start:1"))
    }

    // MARK: - Start outcomes

    @Test
    fun testOwnerStartTypedRejectionIsSurfaceAsNumericFailure() = runBlocking {
        val native = FakeNative()
        native.startStatus = -204
        val exchange = FakeExchange()
        exchange.repeat = { request -> gatewayResponse(request.requestId()) }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("owner_start_-204"), subject.capability.value)
        val reason = (subject.capability.value as RuntimeBootstrapCapability.Failed).reason
        assertFalse(reason.contains("floe-runtime"))
        assertFalse(reason.contains("0123456789abcdef"))
    }

    @Test
    fun testHappyPathEffectAcceptedThenOwnedStoreReady() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder("", sequence = 0))
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), sequence = 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
        assertEquals(listOf(1L), native.startEpochs.toList())
        assertTrue(native.startRoots[0].startsWith("/data/user/0/"))
        assertEquals(32, native.startTokens[0].length)
        // Effect envelope must match the frozen v3 validator requirements,
        // decoded structurally (never a regex over the raw request).
        val effectRequest = exchange.requests.last()
        val root = Json.parseToJsonElement(effectRequest).jsonObject
        assertEquals(3L, root["version"]!!.jsonPrimitive.content.toLong())
        assertEquals(root.requestId(), root["requestID"]!!.jsonPrimitive.content)
        val envelope = root["envelope"]!!.jsonObject
        assertEquals("floe.effect-cursor/3", envelope["schema"]!!.jsonPrimitive.content)
        assertEquals("applicationConfiguration", envelope["scope"]!!.jsonPrimitive.content)
        assertEquals("system", envelope["configurationScope"]!!.jsonPrimitive.content)
        assertEquals("effect.poll", envelope["command"]!!.jsonPrimitive.content)
        assertEquals(root.requestId(), envelope["correlationID"]!!.jsonPrimitive.content)
        // Admission stays the typed barrier, parsed from the REAL status.
        val admission = subject.domainAdmission.value
        assertTrue(admission is RuntimeDomainAdmission.Blocked)
        assertEquals(
            listOf("providerConfigurationDomain", "runDomain"),
            (admission as RuntimeDomainAdmission.Blocked).missingBindings)
    }

    @Test
    fun testSecurityCorpusFrozenBeforeNativeStart() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder("", sequence = 0))
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), sequence = 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(
            native, exchange, gateway,
            corpusInstaller = RuntimeSecurityCorpusInstaller {
                native.events.add("corpus")
                0
            },
        )
        subject.bootstrap()
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
        // The trusted corpus freeze is a PRE-start step of the SAME trusted
        // bootstrap: the Root must already see the frozen bytes when its
        // composition builds the RunIngressContext.
        assertEquals(listOf("corpus", "load", "start:1", "status"),
            native.events.toList())
    }

    @Test
    fun testSecurityCorpusRefusalIsDiagnosedAndNeverFabricatesAGate() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder("", sequence = 0))
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), sequence = 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val diagnostics = CopyOnWriteArrayList<String>()
        val subject = coordinator(
            native, exchange, gateway,
            corpusInstaller = RuntimeSecurityCorpusInstaller { -423 },
            diagnostics = { diagnostics.add(it) },
        )
        subject.bootstrap()
        // The lifecycle itself is unchanged (store ready); the corpus fact is
        // reported honestly and the run gate keeps its typed corpusAbsent
        // refusal because nothing was frozen. No synthetic/permissive gate.
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
        assertTrue(diagnostics.contains("security_corpus_freeze_-423"))
        assertEquals(listOf("load", "start:1", "status"), native.events.toList())
    }

    @Test
    fun testSecurityCorpusInstallerFailureIsDiagnosedWithoutAbortingBootstrap() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder("", sequence = 0))
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), sequence = 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val diagnostics = CopyOnWriteArrayList<String>()
        val subject = coordinator(
            native, exchange, gateway,
            corpusInstaller = RuntimeSecurityCorpusInstaller {
                throw IllegalStateException("asset missing")
            },
            diagnostics = { diagnostics.add(it) },
        )
        subject.bootstrap()
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
        assertTrue(diagnostics.contains("security_corpus_unavailable"))
        assertEquals(listOf("load", "start:1", "status"), native.events.toList())
    }

    @Test
    fun testBootstrapFailedEffectCarriesTypedCode() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(failedEffectJson("schemaVersionMismatch"), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_failed_schemaVersionMismatch"),
            subject.capability.value)
    }

    @Test
    fun testEffectReceiptNotFoundIsTypedFailure() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = { request ->
            """{"version":3,"requestID":"${request.requestId()}","ok":false,""" +
                """"error":"runtimeUnavailable","reason":"effectReceiptNotFound"}"""
        }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effectReceiptNotFound"),
            subject.capability.value)
    }

    @Test
    fun testBootstrapEffectTimeoutIsHonestFailure() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = effectPageResponder("", sequence = 0)
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_timeout"),
            subject.capability.value)
    }

    @Test
    fun testStoreReadbackMismatchNeverClaimsReady() = runBlocking {
        val native = FakeNative()
        native.statusJson = statusJson(1, ownedStoreReady = false)
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("store_readback_mismatch"),
            subject.capability.value)
    }

    @Test
    fun testDomainReadyClaimIsIgnoredByCoordinator() = runBlocking {
        val native = FakeNative()
        native.statusJson = statusJson(1, domainRuntimeReady = true)
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
        assertTrue(subject.domainAdmission.value is RuntimeDomainAdmission.Blocked)
    }

    @Test
    fun testUnreadableStatusDoesNotClaimReady() = runBlocking {
        val native = FakeNative()
        native.statusJson = null
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("store_readback_unreadable"),
            subject.capability.value)
    }

    // MARK: - Shutdown / accepted-owner proof

    @Test
    fun testShutdownNotInstalledCountsAsStoppedWithoutNativeCall() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        assertTrue(subject.shutdown())
        assertEquals(RuntimeBootstrapCapability.Stopped, subject.capability.value)
        // No accepted-start proof => never call native stop on another owner.
        assertTrue(native.stopEpochs.isEmpty())
        assertEquals(0, native.events.count { it.startsWith("stop") })
    }

    @Test
    fun testShutdownNotInstalledAfterAcceptedStartCountsAsStopped() = runBlocking {
        val native = FakeNative()
        native.stopStatus = -207
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
        assertTrue(subject.shutdown())
        assertEquals(RuntimeBootstrapCapability.Stopped, subject.capability.value)
        assertEquals(listOf(1L), native.stopEpochs.toList())
        assertEquals(listOf("0123456789abcdef0123456789abcdef"), native.stopTokens.toList())
    }

    @Test
    fun testShutdownAcceptedAfterRealDrain() = runBlocking {
        val native = FakeNative()
        native.stopResult = "op:v1:" + "1".repeat(32)
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        exchange.enqueue(effectPageResponder(
            """{"sequence":1,"kind":"accepted","detail":[{"key":"dbClosed","value":"true"}]}""",
            1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertTrue(subject.shutdown())
        assertEquals(RuntimeBootstrapCapability.Stopped, subject.capability.value)
        assertEquals(listOf(1L), native.stopEpochs.toList())
        // Admission reverts to the full honest barrier after teardown.
        assertEquals(
            RuntimeBootstrapCoordinator.STATIC_MISSING_BINDINGS,
            (subject.domainAdmission.value as RuntimeDomainAdmission.Blocked).missingBindings)
    }

    @Test
    fun testShutdownTimeoutKeepsFailureAndIsRetryable() = runBlocking {
        val native = FakeNative()
        native.stopResult = "op:v1:" + "2".repeat(32)
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        exchange.repeat = effectPageResponder("", sequence = 0)
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway, timings = RuntimeBootstrapTimings(
            effectPollIntervalMillis = 1, bootstrapDeadlineMillis = 50,
            shutdownDeadlineMillis = 30))
        subject.bootstrap()
        assertFalse(subject.shutdown())
        assertTrue(subject.capability.value is RuntimeBootstrapCapability.Failed)
        // Retry retains the accepted proof and re-issues ownerStop with it.
        assertFalse(subject.shutdown())
        assertEquals(2, native.events.count { it.startsWith("stop:") })
        assertEquals(listOf(1L, 1L), native.stopEpochs.toList())
    }

    @Test
    fun testStaleShutdownProofIsNotRetried() = runBlocking {
        val native = FakeNative()
        native.stopStatus = -204
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertFalse(subject.shutdown())
        assertEquals(
            RuntimeBootstrapCapability.Failed("owner_stop_stale"),
            subject.capability.value)
        // A stale coordinator never retries against the newer owner.
        assertFalse(subject.shutdown())
        assertEquals(1, native.events.count { it.startsWith("stop:") })
    }

    @Test
    fun testStartIsIdempotentPublicationSequence() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val emissions = CopyOnWriteArrayList<RuntimeBootstrapCapability>()
        val subject = coordinator(native, exchange, gateway)
        val collector = launch(Dispatchers.Unconfined) {
            subject.capability.collect { emissions.add(it) }
        }
        subject.start()
        subject.start() // second start must be ignored
        withTimeout(2_000) {
            while (subject.capability.value !is RuntimeBootstrapCapability.OwnedStoreReady) {
                kotlinx.coroutines.yield()
            }
        }
        collector.cancel()
        assertEquals(1, native.events.count { it.startsWith("start:") })
        // StateFlow CONFLATES intermediate values, so a fast publish sequence
        // may legitimately skip WaitingGateway/Starting. The publication
        // sequence contract is monotonically non-regressing and ends Ready.
        fun rank(value: RuntimeBootstrapCapability): Int = when (value) {
            is RuntimeBootstrapCapability.Idle -> 0
            is RuntimeBootstrapCapability.WaitingGateway -> 1
            is RuntimeBootstrapCapability.Starting -> 2
            is RuntimeBootstrapCapability.OwnedStoreReady -> 3
            is RuntimeBootstrapCapability.Failed -> 4
            is RuntimeBootstrapCapability.Stopped -> 5
        }
        var previous = -1
        for (value in emissions.toList()) {
            assertTrue("publication must not regress: $emissions",
                rank(value) >= previous)
            previous = rank(value)
        }
        assertTrue("Starting/OwnedStoreReady must be published: $emissions",
            emissions.any { it is RuntimeBootstrapCapability.Starting } ||
                emissions.any { it is RuntimeBootstrapCapability.OwnedStoreReady })
        assertEquals(
            RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
    }

    // MARK: - RB1-R6: structured parsing is strict

    @Test
    fun testGatewayReadbackRejectsStringBooleanAndWrongRequestID() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.repeat = { request ->
            """{"version":2,"requestID":"${request.requestId()}","ok":true,""" +
                """"secretBackend":{"registered":"true","availability":"AVAILABLE",""" +
                """"memoryFallback":false}}"""
        }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("gateway_readback_malformed"),
            subject.capability.value)
        assertFalse(native.loaded)
        // Wrong requestID is equally malformed.
        val exchange2 = FakeExchange()
        exchange2.repeat = { request ->
            gatewayResponse(request.requestId().replace("rb1-readback", "other"))
        }
        val subject2 = coordinator(FakeNative(), exchange2, gateway)
        subject2.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("gateway_readback_malformed"),
            subject2.capability.value)
    }

    @Test
    fun testEffectPageRejectsWrongCorrelationOrReceipt() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = { request ->
            effectPage("wrong-correlation", request.effectReceipt(),
                acceptedEffectJson(), 1)
        }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_protocol_mismatch"),
            subject.capability.value)
    }

    @Test
    fun testEffectPageRejectsStringSequenceAndNestedFakeFlags() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = { request ->
            // sequence is a JSON string and `ok` is a nested fake flag; the
            // item must never be interpreted as a successful terminal.
            effectPage(request.requestId(), request.effectReceipt(),
                """{"sequence":"1","kind":"accepted","ok":true,""" +
                    """"detail":[{"key":"ownedStoreReady","value":"true"}]}""",
                1)
        }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_protocol_mismatch"),
            subject.capability.value)
    }

    @Test
    fun testEffectPageRejectsForeignSchemaAndMalformedJSON() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = { request ->
            effectPage(request.requestId(), request.effectReceipt(),
                acceptedEffectJson(), 1).replace("floe.effect-cursor/3",
                "floe.command-envelope/3")
        }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_protocol_mismatch"),
            subject.capability.value)
        val malformed = coordinator(FakeNative(), FakeExchange(), gateway)
        val exchange2 = FakeExchange()
        exchange2.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange2.repeat = { request ->
            """{"version":3,"requestID":"${request.requestId()}","ok":true,""" +
                """"schema":"floe.effect-cursor/3","correlationID":"${request.requestId()}",""" +
                """"cursor":{"operationReceiptID":"${request.effectReceipt()}","sequence":1},""" +
                """"effects":[},"hasMore":false,"resyncRequired":false}"""
        }
        val subject2 = coordinator(FakeNative(), exchange2, gateway)
        subject2.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_protocol_mismatch"),
            subject2.capability.value)
        assertFalse(malformed.capability.value is RuntimeBootstrapCapability.OwnedStoreReady)
    }

    @Test
    fun testEffectPageRequiresMonotonicSequenceAndTruthfulResync() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        // First page advances to sequence 2 without a terminal.
        exchange.enqueue(effectPageResponder("", sequence = 2))
        // Second page regresses to sequence 1: must fail closed.
        exchange.enqueue(effectPageResponder("", sequence = 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_protocol_mismatch"),
            subject.capability.value)
    }

    @Test
    fun testEffectPageEscapedUnicodeDetailIsAccepted() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(
            """{"sequence":1,"kind":"accepted","detail":[{"key":"note",""" +
                """"value":"\u4f60\u597d"}]}""", 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
    }

    @Test
    fun testStatusRequiresGenerationMatchAndTypedFlags() = runBlocking {
        val native = FakeNative()
        native.statusJson = statusJson(2)   // wrong owner generation
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("store_readback_unreadable"),
            subject.capability.value)
        // A string "true" is not a boolean.
        val native2 = FakeNative()
        native2.statusJson = statusJson(1).replace("\"ownedStoreReady\":true",
            "\"ownedStoreReady\":\"true\"")
        val exchange2 = FakeExchange()
        exchange2.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange2.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val subject2 = coordinator(native2, exchange2, gateway)
        subject2.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("store_readback_unreadable"),
            subject2.capability.value)
    }

    @Test
    fun testStatusEmptyMissingBindingsNeverOverwritesBarrier() = runBlocking {
        val native = FakeNative()
        native.statusJson = statusJson(1, missing = emptyList())
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("store_readback_unreadable"),
            subject.capability.value)
        assertEquals(
            RuntimeBootstrapCoordinator.STATIC_MISSING_BINDINGS,
            (subject.domainAdmission.value as RuntimeDomainAdmission.Blocked).missingBindings)
    }

    @Test
    fun testStatusUnknownFieldsAndEscapedUnicodeTolerated() = runBlocking {
        val native = FakeNative()
        native.statusJson = statusJson(
            1, extra = """"rootFingerprint":"\u4f60\u597d","futureField":{"x":1}""")
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
    }

    @Test
    fun testOversizedEffectResponseRejected() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = { request ->
            // Valid envelope shape inflated beyond the frozen 64 KiB bound.
            val padding = "a".repeat(70_000)
            effectPage(request.requestId(), request.effectReceipt(),
                """{"sequence":1,"kind":"accepted","detail":[{"key":"pad","value":"$padding"}]}""",
                1)
        }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_response_too_large"),
            subject.capability.value)
    }

    @Test
    fun testEffectPageRejectsWrongReceipt() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = { request ->
            effectPage(request.requestId(), "op:v1:" + "f".repeat(32),
                acceptedEffectJson(), 1)
        }
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_protocol_mismatch"),
            subject.capability.value)
    }

    @Test
    fun testEffectResyncWithoutTerminalFailsClosed() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = effectPageResponder("", sequence = 0, resync = true)
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(native, exchange, gateway,
            timings = RuntimeBootstrapTimings(effectPollIntervalMillis = 1,
                bootstrapDeadlineMillis = 250, shutdownDeadlineMillis = 100))
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("bootstrap_effect_resync"),
            subject.capability.value)
    }

    @Test
    fun testStatusWrongRootOrBindingTypesFailClosed() = runBlocking {
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        // A string generation is not a numeric identity.
        val native = FakeNative()
        native.statusJson = statusJson(1).replace("\"generation\":1",
            "\"generation\":\"1\"")
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val subject = coordinator(native, exchange, gateway)
        subject.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("store_readback_unreadable"),
            subject.capability.value)
        // missingBindings must be an array, not a string/object.
        val native2 = FakeNative()
        native2.statusJson = statusJson(1).replace(
            "\"missingBindings\":[\"providerConfigurationDomain\",\"runDomain\"]",
            "\"missingBindings\":\"runDomain\"")
        val exchange2 = FakeExchange()
        exchange2.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange2.enqueue(effectPageResponder(acceptedEffectJson(), 1))
        val subject2 = coordinator(native2, exchange2, gateway)
        subject2.bootstrap()
        assertEquals(
            RuntimeBootstrapCapability.Failed("store_readback_unreadable"),
            subject2.capability.value)
    }

    // MARK: - RB1-R5: late bootstrap after stop cannot publish

    @Test
    fun testLateBootstrapCallbackAfterStopCannotMarkReady() = runBlocking {
        val native = FakeNative()
        val exchange = FakeExchange()
        val gateEntered = CountDownLatch(1)
        val release = CountDownLatch(1)
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.repeat = { request ->
            if (request.effectReceipt() == "op:v1:" + "0".repeat(32)) {
                gateEntered.countDown()
                release.await(5, TimeUnit.SECONDS)
                effectPage(request.requestId(), request.effectReceipt(),
                    acceptedEffectJson(), 1)
            } else {
                effectPage(request.requestId(), request.effectReceipt(),
                    """{"sequence":1,"kind":"accepted"}""", 1)
            }
        }
        native.stopResult = "op:v1:" + "3".repeat(32)
        val gateway = MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready)
        val subject = coordinator(
            native, exchange, gateway,
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            ioDispatcher = Dispatchers.Default)
        subject.start()
        assertTrue(gateEntered.await(5, TimeUnit.SECONDS))
        // Stop while the bootstrap poll is still blocked in the exchange.
        val stopped = async(Dispatchers.Default) { subject.shutdown() }
        assertTrue(stopped.await())
        assertEquals(RuntimeBootstrapCapability.Stopped, subject.capability.value)
        // Release the late accepted bootstrap page. It must not overwrite
        // Stopped or promote OwnedStoreReady.
        release.countDown()
        delay(250)
        assertEquals(RuntimeBootstrapCapability.Stopped, subject.capability.value)
        assertFalse(subject.capability.value is RuntimeBootstrapCapability.OwnedStoreReady)
    }

    // MARK: - Typed carrier (final consumer schema: value/valueBytes, page/pageBytes)

    private val carrierJson = Json { ignoreUnknownKeys = true; isLenient = false }

    private fun canonicalBytes(element: JsonElement): Int =
        element.toString().toByteArray(Charsets.UTF_8).size

    private fun carrierItem(
        sequence: Long,
        page: JsonObject? = null,
        value: JsonObject? = null,
        declaredPageBytes: Int? = null,
        declaredValueBytes: Int? = null,
    ): JsonObject {
        val fields = LinkedHashMap<String, JsonElement>()
        fields["sequence"] = JsonPrimitive(sequence)
        fields["kind"] = JsonPrimitive("accepted")
        if (value != null) {
            fields["value"] = value
            fields["valueBytes"] = JsonPrimitive(declaredValueBytes ?: canonicalBytes(value))
        }
        if (page != null) {
            fields["page"] = page
            fields["pageBytes"] = JsonPrimitive(declaredPageBytes ?: canonicalBytes(page))
        }
        return JsonObject(fields)
    }

    private fun carrierFrame(requestID: String, receipt: String,
                             items: List<JsonObject>, sequence: Long,
                             hasMore: Boolean = false): String {
        val effects = items.joinToString(",") { it.toString() }
        return effectPage(requestID, receipt, effects, sequence, hasMore)
    }

    private fun decodeCarrier(raw: String, correlation: String, receipt: String,
                              afterSequence: Long = 0): RuntimeBootstrapCoordinator.EffectPageResult =
        decodeSubject().parseEffectPage(raw, correlation, receipt, afterSequence)

    private fun decodeSubject(): RuntimeBootstrapCoordinator =
        coordinator(FakeNative(), FakeExchange(),
            MutableStateFlow<SecretGatewayCapability>(SecretGatewayCapability.Ready))

    @Test
    fun typedValueAndPageDecodeWithCanonicalDeclaredBytes() {
        val subject = decodeSubject()
        val value = carrierJson.parseToJsonElement(
            """{"title":"设置","count":2,"ok":true,"nested":{"url":"https://x/a?b=1"}}"""
        ).jsonObject
        val page = carrierJson.parseToJsonElement(
            """{"nextOffset":null,"done":true}"""
        ).jsonObject
        val raw = carrierFrame("carrier-1", "op:v1:abc",
            listOf(carrierItem(1, page = page, value = value)), sequence = 1)
        val decoded = subject.parseEffectPage(raw, "carrier-1", "op:v1:abc", 0)
        assertTrue("decoded=$decoded",
            decoded is RuntimeBootstrapCoordinator.EffectPageResult.Page)
        val pageResult = decoded as RuntimeBootstrapCoordinator.EffectPageResult.Page
        assertEquals(1, pageResult.effects.size)
        val item = pageResult.effects[0]
        assertEquals(value, item.value)
        assertEquals(page, item.page)
        assertEquals(1L, pageResult.nextSequence)
        assertFalse(pageResult.hasMore)
    }

    @Test
    fun declaredValueBytesMismatchIsProtocolMismatch() {
        val subject = decodeSubject()
        val value = carrierJson.parseToJsonElement("""{"a":"b"}""").jsonObject
        val raw = carrierFrame("carrier-2", "op:v1:abc",
            listOf(carrierItem(1, value = value,
                declaredValueBytes = canonicalBytes(value) + 1)), sequence = 1)
        assertEquals(RuntimeBootstrapCoordinator.EffectPageResult.ProtocolMismatch,
            subject.parseEffectPage(raw, "carrier-2", "op:v1:abc", 0))
    }

    @Test
    fun bytesWithoutDocumentIsProtocolMismatch() {
        val subject = decodeSubject()
        val raw = """{"version":3,"requestID":"carrier-3","ok":true,""" +
            """"schema":"floe.effect-cursor/3","correlationID":"carrier-3",""" +
            """"cursor":{"operationReceiptID":"op:v1:abc","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"accepted","valueBytes":12}],""" +
            """"hasMore":false,"resyncRequired":false}"""
        assertEquals(RuntimeBootstrapCoordinator.EffectPageResult.ProtocolMismatch,
            subject.parseEffectPage(raw, "carrier-3", "op:v1:abc", 0))
    }

    @Test
    fun near48KiBCjkEmojiCarrierDecodesWithinBudget() {
        val subject = decodeSubject()
        val content = "中文😀".repeat(4_600)
        val value = JsonObject(mapOf(
            "content" to JsonPrimitive(content),
            "done" to JsonPrimitive(true)))
        val declared = canonicalBytes(value)
        assertTrue("carrier must be genuinely large: $declared", declared > 44_000)
        val raw = carrierFrame("carrier-4", "op:v1:abc",
            listOf(carrierItem(1, value = value)), sequence = 1)
        val decoded = subject.parseEffectPage(raw, "carrier-4", "op:v1:abc", 0)
        assertTrue("decoded=$decoded", decoded is RuntimeBootstrapCoordinator.EffectPageResult.Page)
        val item = (decoded as RuntimeBootstrapCoordinator.EffectPageResult.Page).effects[0]
        assertEquals(value, item.value)
        assertEquals(declared.toLong(),
            item.value.toString().toByteArray(Charsets.UTF_8).size.toLong())
    }

    @Test
    fun overBudgetCarrierIsRejectedWithoutCursorAdvance() {
        val subject = decodeSubject()
        // Two near-48KiB pages in one frame must exceed the 48KiB page budget
        // measured by the decoder itself: typed rejection, never a partial
        // accept and never a cursor advance.
        val chunk = "中".repeat(9_000)
        val first = JsonObject(mapOf("content" to JsonPrimitive(chunk)))
        val second = JsonObject(mapOf("content" to JsonPrimitive(chunk)))
        val raw = carrierFrame("carrier-5", "op:v1:abc",
            listOf(carrierItem(1, value = first), carrierItem(2, value = second)),
            sequence = 2)
        val decoded = subject.parseEffectPage(raw, "carrier-5", "op:v1:abc", 0)
        assertEquals(RuntimeBootstrapCoordinator.EffectPageResult.ProtocolMismatch, decoded)
    }

    @Test
    fun crossLanguageCanonicalCarrierFixtureMatchesSwift() {
        // Fixture emitted by the ACTUAL Swift canonicalizer during host
        // qualification: each case's declared byte count must equal what this
        // pinned kotlinx encoder produces for the same parsed object. This is
        // the cross-language lexeme pin (slash URLs are NOT escaped by
        // kotlinx while Foundation escapes them on the wire).
        val stream = javaClass.classLoader!!
            .getResourceAsStream("rb1-carrier/rb1-carrier-fixtures.json")
        assertNotNull("carrier fixture resource missing", stream)
        val fixture = carrierJson.parseToJsonElement(
            stream!!.bufferedReader(Charsets.UTF_8).use { it.readText() }).jsonObject
        val cases = fixture["cases"] as kotlinx.serialization.json.JsonArray
        assertEquals(7, cases.size)
        for (case in cases) {
            val caseObject = case.jsonObject
            val name = caseObject["name"]!!.jsonPrimitive.content
            val json = caseObject["json"]!!.jsonObject
            val declared = caseObject["canonicalBytes"]!!.jsonPrimitive.content.toLong()
            assertEquals("canonical bytes mismatch for $name",
                declared, canonicalBytes(json).toLong())
        }
    }
}

private fun statusJson(
    generation: Long,
    ownedStoreReady: Boolean = true,
    domainRuntimeReady: Boolean = false,
    phase: String = "starting",
    missing: List<String> = listOf("providerConfigurationDomain", "runDomain"),
    retiring: Boolean = false,
    extra: String = "",
): String {
    val bindings = missing.joinToString(",") { "\"$it\"" }
    return """{"version":1,"phase":"$phase","gatewayRegistered":true,""" +
        """"ownedStoreReady":$ownedStoreReady,"ownedStorePhase":"${if (ownedStoreReady) "ready" else "failed"}",""" +
        """"domainRuntimeReady":$domainRuntimeReady,"businessCapabilities":[],""" +
        """"generation":$generation,"retiring":$retiring,""" +
        """"ordinaryRuntimeAdmission":"blocked","missingBindings":[$bindings]""" +
        (if (extra.isEmpty()) "" else ",$extra") + "}"
}

private fun JsonObject.requestId(): String =
    this["requestID"]!!.jsonPrimitive.content

private fun JsonObject.effectReceipt(): String =
    this["envelope"]!!.jsonObject["effect"]!!.jsonObject["operationReceiptID"]!!
        .jsonPrimitive.content