// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.pcap

import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PcapAnalyzerTest {
    private val analysisID = UUID.fromString("10000000-0000-4000-8000-000000000001").toString()
    private val analyzer = PcapAnalyzer()

    private fun options(
        detailed: Boolean = false,
        budget: Long = 30_000,
        cancel: PcapCancellation = PcapCancellation.NONE,
        maxFlows: Int = PcapLimits.MAX_FLOW_KEYS,
        maxDns: Int = PcapLimits.MAX_DNS_RECORDS,
    ) = PcapAnalysisOptions(
        analysisID = analysisID,
        sourceLabel = "capture.pcap",
        detailed = detailed,
        timeBudgetMillis = budget,
        cancellation = cancel,
        maxFlowKeys = maxFlows,
        maxDnsRecords = maxDns,
    )

    @Test
    fun parsesLittleEndianMicroPcapAndKeepsLocalLiterals() {
        val summary = analyzer.analyze(BytePcapSource(PcapFixtures.ethernetIpv4Tcp()), options())
        assertEquals(PcapCaptureFormat.PCAP, summary.format)
        assertEquals(1L, summary.packetCount)
        assertEquals(1L, summary.totalFlowCount)
        assertEquals("tcp", summary.protocols.first { it.protocol == PcapProtocol.TCP }.protocol.wire)
        val flow = summary.flows.single()
        assertEquals(12_345, flow.source.port)
        assertEquals(80, flow.destination.port)
        assertEquals("10.0.0.1", flow.source.address)
        assertFalse(summary.limitations.joinToString().contains("10.0.0.1"))
        assertEquals(1, summary.http.size)
        assertEquals("GET", summary.http.single().methodOrStatus)
        assertEquals("example.test", summary.http.single().host)
        assertEquals("/index.html", summary.http.single().path)
        // Local storage keeps useful literals; exports/tools redact by default.
        val view = PcapSummaryView.of(summary, PcapFilters())
        assertFalse(PcapReportRenderer.renderViewJson(view, detailed = false).contains("10.0.0.1"))
        assertTrue(PcapReportRenderer.renderViewJson(view, detailed = true).contains("10.0.0.1"))
        assertEquals(PcapAnalysisStatus.OK, summary.status)
        assertEquals(1_700_000_000_500L, summary.flows.single().firstEpochMillis)
    }

    @Test
    fun detailedAnalysisRetainsOnlyBoundedDisplayIdentifiers() {
        val summary = analyzer.analyze(
            BytePcapSource(PcapFixtures.ethernetIpv4Tcp()), options(detailed = true),
        )
        assertEquals("10.0.0.1", summary.flows.single().source.address)
        assertEquals("example.test", summary.http.single().host)
        assertEquals("/index.html", summary.http.single().path)
    }

    @Test
    fun parsesBigEndianNanosecondTimestamps() {
        val summary = analyzer.analyze(BytePcapSource(PcapFixtures.bigEndianNano()), options())
        assertEquals(1L, summary.packetCount)
        // 123_456_789 ns = 123 ms.
        assertEquals(1_700_000_000_123L, summary.flows.single().firstEpochMillis)
    }

    @Test
    fun parsesPcapngMultipleInterfacesAndSections() {
        val summary = analyzer.analyze(BytePcapSource(PcapFixtures.pcapNgMulti()), options())
        assertEquals(PcapCaptureFormat.PCAPNG, summary.format)
        assertEquals(3L, summary.packetCount)
        assertEquals(3L, summary.totalFlowCount)
        assertEquals(3, summary.interfaces.size)
        assertEquals(1, summary.interfaces[0].linkType)
        assertEquals(101, summary.interfaces[1].linkType)
        assertEquals(1, summary.interfaces[2].linkType)
        assertEquals(1, summary.http.size)
        assertEquals("ng.example.test", summary.http.single().host)
    }

    @Test
    fun decodesVlanIpv6DnsSllSll2AndRaw() {
        val vlan = analyzer.analyze(BytePcapSource(PcapFixtures.ethernetIcmpVlan()), options())
        assertEquals(1L, vlan.packetCount)
        assertEquals(PcapProtocol.ICMP, vlan.protocols.single { it.protocol == PcapProtocol.ICMP }.protocol)

        val dns = analyzer.analyze(BytePcapSource(PcapFixtures.ethernetIpv6DnsQuery()), options())
        assertEquals(1L, dns.packetCount)
        assertEquals(1, dns.dns.size)
        assertEquals("query", dns.dns.single().direction)
        assertEquals("A", dns.dns.single().recordType)
        assertEquals("www.example.test", dns.dns.single().name)

        val sll = analyzer.analyze(BytePcapSource(PcapFixtures.sllIpv4Udp()), options())
        assertEquals(1, sll.dns.size)
        val sll2 = analyzer.analyze(BytePcapSource(PcapFixtures.sll2Ipv4Udp()), options())
        assertEquals(1, sll2.dns.size)
        val raw = analyzer.analyze(BytePcapSource(PcapFixtures.rawIpv4()), options())
        assertEquals(1L, raw.packetCount)
        assertEquals(1L, raw.totalFlowCount)

        val unknown = analyzer.analyze(BytePcapSource(PcapFixtures.unknownLink()), options())
        assertEquals(1L, unknown.packetCount)
        assertEquals(1L, unknown.unsupportedPacketCount)
        assertEquals(PcapAnalysisStatus.PARTIAL, unknown.status)
    }

    @Test
    fun truncatedAndInvalidCapturesAreHonestPartialOrFailed() {
        val truncated = analyzer.analyze(BytePcapSource(PcapFixtures.truncatedPcap()), options())
        assertTrue(truncated.status != PcapAnalysisStatus.OK)
        assertTrue(truncated.sourceTruncated)

        val empty = analyzer.analyze(BytePcapSource(ByteArray(0)), options())
        assertEquals(PcapAnalysisStatus.FAILED, empty.status)
        assertTrue(empty.limitations.any { it.contains("empty") })

        val garbage = analyzer.analyze(BytePcapSource("not a capture".toByteArray()), options())
        assertEquals(PcapAnalysisStatus.FAILED, garbage.status)
        assertTrue(garbage.limitations.any { it.contains("not a PCAP") })

        val tooLarge = analyzer.analyze(object : PcapSource {
            override val sizeBytes: Long = PcapLimits.MAX_SOURCE_BYTES + 1
            override val label: String? = "huge.pcap"
            override fun openStream() = ByteArrayInputStream(ByteArray(0))
        }, options())
        assertEquals(PcapAnalysisStatus.FAILED, tooLarge.status)
    }

    @Test
    fun cancellationAndTimeBudgetStopAtTheParsedPrefix() {
        val calls = AtomicInteger(0)
        val cancel = PcapCancellation {
            // Two records of the two-record capture: stop before the second.
            calls.incrementAndGet() >= 2
        }
        val summary = analyzer.analyze(BytePcapSource(PcapFixtures.ethernetIpv4Tcp()), options(cancel = cancel))
        assertEquals(PcapAnalysisStatus.PARTIAL, summary.status)
        assertTrue(summary.cancelled)
        assertEquals("cancelled", summary.stoppedReason)

        val budget = analyzer.analyze(BytePcapSource(PcapFixtures.ethernetIpv4Tcp()), options(budget = 0))
        assertEquals(PcapAnalysisStatus.PARTIAL, budget.status)
        assertEquals("timeBudget", budget.stoppedReason)
    }

    @Test
    fun flowTableDnsAndHttpRingsAreBounded() {
        val summary = analyzer.analyze(
            BytePcapSource(PcapFixtures.ethernetIpv4Tcp()),
            options(maxFlows = 1, maxDns = 0),
        )
        assertEquals(1, summary.flows.size)
        assertEquals(0, summary.dns.size)

        val bounded = analyzer.analyze(
            BytePcapSource(PcapFixtures.pcapNgMulti()),
            options(maxFlows = 1, maxDns = 0),
        )
        assertEquals(1, bounded.flows.size)
        assertTrue(bounded.flowTableOverflow >= 1)
        assertTrue(bounded.status == PcapAnalysisStatus.PARTIAL)
    }

    @Test
    fun filtersNarrowFlowsAndExtractionWithoutChangingTotals() {
        val summary = analyzer.analyze(BytePcapSource(PcapFixtures.pcapNgMulti()), options())
        val tcp = PcapSummaryView.of(
            summary, PcapFilters(protocols = setOf(PcapProtocol.TCP)),
        )
        assertEquals(1, tcp.matchedFlows.size)
        assertEquals("tcp", tcp.matchedFlows.single().protocol.wire)
        val http = PcapSummaryView.of(summary, PcapFilters(services = setOf(PcapServiceFilter.HTTP)))
        assertEquals(1, http.matchedHttp.size)
        assertEquals(0, http.matchedDns.size)
        val port = PcapSummaryView.of(summary, PcapFilters(port = 80))
        assertEquals(1, port.matchedFlows.size)
        val address = PcapSummaryView.of(
            summary, PcapFilters(address = "10.5.0.1"),
        )
        assertEquals(1, address.matchedFlows.size)
        val time = PcapSummaryView.of(
            summary,
            PcapFilters(
                startEpochMillis = PcapFixtures.T0_SECONDS * 1000 + 150,
                endEpochMillis = PcapFixtures.T0_SECONDS * 1000 + 250,
            ),
        )
        assertEquals(1, time.matchedFlows.size)
        assertEquals(1L, tcp.matchedPackets)
    }

    @Test
    fun toolSummaryStaysWithinTheBridgeHeadroomAndRedactsDetailedIdentifiers() {
        val summary = analyzer.analyze(
            BytePcapSource(PcapFixtures.pcapNgMulti()), options(detailed = true),
        )
        val view = PcapSummaryView.of(summary, PcapFilters())
        val reply = PcapReportRenderer.renderToolSummary(view)
        assertTrue(reply.toByteArray(Charsets.UTF_8).size <= PcapReportRenderer.MAX_TOOL_REPLY_BYTES)
        assertFalse(reply.contains("10.5.0.1"))
        assertFalse(reply.contains("ng.example.test"))
        val root = JSONObject(reply)
        assertEquals("redacted", root.getString("privacy"))
        assertEquals("floe.pcap-tool-summary.v1", root.getString("schema"))
    }

    @Test
    fun codecRoundTripsAndExportsAreBounded() {
        val summary = analyzer.analyze(BytePcapSource(PcapFixtures.pcapNgMulti()), options(detailed = true))
        val json = PcapSummaryCodec.encode(summary)
        val decoded = PcapSummaryCodec.decode(json)
        assertEquals(summary.analysisID, decoded.analysisID)
        assertEquals(summary.packetCount, decoded.packetCount)
        assertEquals(summary.flows.size, decoded.flows.size)
        assertEquals(summary.http.size, decoded.http.size)

        val view = PcapSummaryView.of(decoded, PcapFilters(protocols = setOf(PcapProtocol.TCP)))
        val viewJson = PcapReportRenderer.renderViewJson(view)
        assertTrue(viewJson.toByteArray(Charsets.UTF_8).size <= PcapLimits.MAX_RESULT_BYTES)
        assertEquals("floe.pcap-analysis-view.v1", JSONObject(viewJson).getString("schema"))
        val markdown = PcapReportRenderer.renderMarkdown(view)
        assertTrue(markdown.contains("Floe capture analysis"))
        val csv = PcapReportRenderer.renderCsv(view)
        assertTrue(csv.startsWith("firstSeen,lastSeen"))
        assertEquals(2, csv.lines().filter { it.isNotBlank() }.size)
    }
}

class PcapAnalysisStoreTest {
    private fun summary(): PcapSummary =
        PcapAnalyzer().analyze(
            BytePcapSource(PcapFixtures.ethernetIpv4Tcp()),
            PcapAnalysisOptions(
                analysisID = "20000000-0000-4000-8000-000000000002",
                sourceLabel = "store.pcap",
            ),
        )

    @Test
    fun writesReopensListsAndDeletesAtomically() {
        val root = Files.createTempDirectory("floe-pcap-store").toFile()
        try {
            val store = PcapAnalysisStore(root)
            val stored = store.write(summary())
            assertTrue(stored.summaryFile.isFile)
            assertTrue(stored.manifestFile.isFile)
            val reopened = store.read(stored.analysisID)
            assertNotNull(reopened)
            assertEquals(stored.json, reopened!!.json)
            assertEquals(1, store.list().size)
            assertEquals(stored.analysisID, store.list().single().analysisID)
            assertTrue(store.delete(stored.analysisID))
            assertNull(store.read(stored.analysisID))
            assertFalse(store.delete(stored.analysisID))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test(expected = java.io.IOException::class)
    fun refusesToOverwriteAnExistingAnalysis() {
        val root = Files.createTempDirectory("floe-pcap-store-duplicate").toFile()
        try {
            val store = PcapAnalysisStore(root)
            store.write(summary())
            store.write(summary())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun ignoresMissingOrTamperedSummaries() {
        val root = Files.createTempDirectory("floe-pcap-store-tamper").toFile()
        try {
            val store = PcapAnalysisStore(root)
            val stored = store.write(summary())
            stored.summaryFile.writeText("{}")
            assertNull(store.read(stored.analysisID))
            assertTrue(store.list().isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun explicitAgentShareIsPersistedSeparatelyFromTheSummary() {
        val root = Files.createTempDirectory("floe-pcap-store-grant").toFile()
        try {
            val store = PcapAnalysisStore(root)
            val stored = store.write(summary(), ownerTaskId = null,
                ownerWorkspaceId = null, agentReadable = false)
            assertFalse(stored.agentReadable)
            val shared = store.setAgentReadable(stored.analysisID, true)
            assertNotNull(shared)
            assertTrue(shared!!.agentReadable)
            assertTrue(store.read(stored.analysisID)!!.agentReadable)
            assertTrue(store.list().single().agentReadable)
            assertTrue(store.setAgentReadable(stored.analysisID, false)!!.agentReadable == false)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun writesAnUppercaseIdentityToOneLowercaseDirectory() {
        val root = Files.createTempDirectory("floe-pcap-store-canonical").toFile()
        try {
            val lower = "a6e433a5-83cf-4ba5-9cb1-63a86081fbcb"
            val upper = lower.uppercase(java.util.Locale.ROOT)
            val store = PcapAnalysisStore(root)
            val stored = store.write(
                summary().copy(analysisID = upper),
                ownerTaskId = null, ownerWorkspaceId = null, agentReadable = true,
            )
            assertEquals("pcap-$lower", stored.directory.name)
            assertEquals(lower, stored.analysisID)
            assertEquals(lower, JSONObject(stored.json).getString("analysisID"))
            val reopened = store.read(upper)
            assertNotNull(reopened)
            assertEquals("pcap-$lower", reopened!!.directory.name)
            assertEquals(lower, reopened.analysisID)
            assertTrue(reopened.agentReadable)
            assertEquals(lower, store.list().single().analysisID)
            assertTrue(store.setAgentReadable(upper, false)!!.agentReadable.not())
            assertTrue(store.delete(upper))
            assertNull(store.read(upper))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun readsAnUppercaseIdentityWrittenInTheLowercaseAppForm() {
        val root = Files.createTempDirectory("floe-pcap-store-uppercase-read").toFile()
        try {
            val lower = "a6e433a5-83cf-4ba5-9cb1-63a86081fbcb"
            val upper = lower.uppercase(java.util.Locale.ROOT)
            val store = PcapAnalysisStore(root)
            store.write(summary().copy(analysisID = lower), agentReadable = true)
            val reopened = store.read(upper)
            assertNotNull(reopened)
            assertEquals(lower, reopened!!.analysisID)
            assertEquals("pcap-$lower", reopened.directory.name)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun plainFilesAreNotAnalyses() {
        val root = Files.createTempDirectory("floe-pcap-store-misc").toFile()
        try {
            File(root, "pcap-not-a-uuid").mkdir()
            val store = PcapAnalysisStore(root)
            assertTrue(store.list().isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }
}
