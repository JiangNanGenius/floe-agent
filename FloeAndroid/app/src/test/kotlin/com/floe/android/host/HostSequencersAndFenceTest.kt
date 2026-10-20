// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authored NOTRUN. */
class HostSequencersAndFenceTest {

    @Test
    fun identicalSameFrameFailureIncrementsSequence() {
        val sequencer = SaveFailureSequencer()
        val identity = "editor-1" to 1L
        assertEquals(0L, sequencer.current(identity.first, identity.second))
        // Two identical failures in the same composition frame still count
        // as two distinct failed attempts.
        assertEquals(1L, sequencer.next(identity.first, identity.second))
        assertEquals(2L, sequencer.next(identity.first, identity.second))
        assertEquals(2L, sequencer.current(identity.first, identity.second))
        // A new epoch starts over at 0.
        assertEquals(0L, sequencer.current(identity.first, 2L))
        assertEquals(1L, sequencer.next(identity.first, 2L))
        // A different editor id is independent.
        assertEquals(1L, sequencer.next("editor-2", 1L))
    }

    @Test
    fun sequencerNeverDecreasesAndResetIsExplicit() {
        val sequencer = SaveFailureSequencer()
        sequencer.next("e", 1L)
        sequencer.next("e", 1L)
        sequencer.reset("e", 1L)
        assertEquals(0L, sequencer.current("e", 1L))
    }

    @Test
    fun attachmentStagePayloadCarriesMetadataOnly() {
        val payload = AttachmentWire.stagePayload(
            attachmentID = "att-1",
            displayName = "report.pdf",
            mimeType = "application/pdf",
            kind = "document",
            byteCount = 1024,
            sha256 = "ab".repeat(32),
            stagingFile = "att-1.bin",
        )
        assertTrue(payload.containsKey("stagingFile"))
        assertTrue(payload.containsKey("sha256"))
        // No binary, no content URI, no absolute source path.
        assertTrue(payload.toString().length < 1024)
        assertEquals("att-1.bin", (payload["stagingFile"] as? kotlinx.serialization.json.JsonPrimitive)?.content)
    }

    @Test
    fun firstProviderAdmittedAtStoreReadyWithoutAiReady() {
        val readiness = RuntimeHostReadiness(
            gateway = RuntimeHostReadiness.GatewayReadiness.Ready,
            store = RuntimeHostReadiness.StoreReadiness.OwnedStoreReady,
            domains = mapOf(
                "providerConfigurationDomain" to
                    RuntimeHostReadiness.DomainReadiness.Available(1),
                "runDomain" to RuntimeHostReadiness.DomainReadiness.Blocked(listOf("runDomain")),
            ),
        )
        // Provider configuration works once the store + config handler exist,
        // even while the run domain is still blocked — no circular gate.
        assertTrue(readiness.providerConfigurationAdmitted)
        assertTrue(readiness.storeReady)
        assertTrue(!readiness.runDomainAdmitted)
    }

    @Test
    fun blockedDomainNeverAppearsAvailable() {
        val readiness = RuntimeHostReadiness(
            gateway = RuntimeHostReadiness.GatewayReadiness.Ready,
            store = RuntimeHostReadiness.StoreReadiness.OwnedStoreReady,
            domains = mapOf("temporaryDomain" to RuntimeHostReadiness.DomainReadiness.Blocked(listOf("x"))),
        )
        assertTrue(!readiness.temporaryDomainAdmitted)
        assertTrue(!readiness.domainAvailable("temporaryDomain"))
    }

    @Test
    fun privacyConfirmationRequiresExactEpochTap() = runBlocking {
        val exchange = object : HostBridgeExchange {
            override fun exchange(request: String): String {
                val correlation = correlationOf(request)
                return when {
                    request.contains("\"operation\":\"effect.poll\"") -> {
                        val receipt = receiptOf(request)
                        val summaryValue = """{"history":{"conversationCount":2,"runCount":3,"persistedGrantCount":1,"inMemoryGrantCount":0,"revision":"sha256:hist"},"modelConfiguration":{"providerCount":1,"modelCount":2,"secretReferenceCount":1,"preferencesSyncRevision":4,"revision":"sha256:mcfg"},"partial":false}"""
                        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","page":$summaryValue}],"hasMore":false,"resyncRequired":false}"""
                    }
                    else -> """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:prv"}"""
                }
            }
        }
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settings.privacy", true, emptyList())
        host.settings.refreshPrivacySummary()
        kotlinx.coroutines.delay(200)
        val summary = host.settings.state.value.privacy.summary
        assertTrue(summary != null)
        assertEquals(2L, summary!!.conversationCount)
        assertEquals("sha256:hist", summary.historyRevision)
        // Consent: the token mints ONLY for a tap on the CURRENT preview
        // epoch; a stale/wrong-epoch tap gets nothing.
        val epoch = host.settings.privacyPreviewEpoch
        assertNull(host.settings.mintClearConfirmation(
            SettingsHostController.PrivacyClearAction.HISTORY, epoch + 99))
        val token = host.settings.mintClearConfirmation(
            SettingsHostController.PrivacyClearAction.HISTORY, epoch)
        assertEquals("sha256:hist", token)
    }

    @Test
    fun privacyNullRemainingRequiresTypedFailureAndPartial() = runBlocking {
        val exchange = object : HostBridgeExchange {
            override fun exchange(request: String): String {
                val correlation = correlationOf(request)
                return when {
                    request.contains("\"operation\":\"effect.poll\"") -> {
                        val receipt = receiptOf(request)
                        val summaryValue = """{"history":{"conversationCount":2,"runCount":3,"persistedGrantCount":1,"inMemoryGrantCount":0,"revision":"sha256:hist"},"modelConfiguration":{"providerCount":1,"modelCount":2,"secretReferenceCount":1,"preferencesSyncRevision":4,"revision":"sha256:mcfg"},"remainingFailure":"unstableGrantSnapshot","partial":true}"""
                        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","page":$summaryValue}],"hasMore":false,"resyncRequired":false}"""
                    }
                    else -> """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:prv"}"""
                }
            }
        }
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settings.privacy", true, emptyList())
        host.settings.refreshPrivacySummary()
        kotlinx.coroutines.delay(200)
        val summary = host.settings.state.value.privacy.summary
        // remaining is null with the typed failure surfaced — never zeros.
        assertTrue(summary != null && summary.remaining == null)
        assertEquals("unstableGrantSnapshot", summary!!.remainingFailure)
        assertTrue(summary.partial)
    }


    private fun testHost(exchange: HostBridgeExchange): RuntimeHost {
        val client = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        )
        val host = RuntimeHost(
            commandClient = client,
            gatewayCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.SecretGatewayCapability.Loading),
            bootstrapCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        )
        return host
    }

}
