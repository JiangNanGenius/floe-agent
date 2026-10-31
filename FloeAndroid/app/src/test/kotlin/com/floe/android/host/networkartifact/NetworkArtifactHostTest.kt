// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

import com.floe.android.core.networkmonitor.CoverageSessionStore
import com.floe.android.core.pcap.PcapAnalysisStore
import com.floe.android.core.pcap.PcapCancellation
import com.floe.android.feature.network.CoverageProbeRequestUi
import com.floe.android.feature.network.CoverageSampleRequest
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PcapImportRunnerTest {
    private val fixture = pcapFixture()
    private val analysisID = UUID.fromString("50000000-0000-4000-8000-000000000005").toString()

    @Test
    fun copiesAnalysesStoresAndNeverLeavesTheRawCopy() {
        val root = Files.createTempDirectory("floe-artifact-import").toFile()
        try {
            val store = PcapAnalysisStore(File(root, "pcap"))
            val staging = File(root, "staging")
            val progress = mutableListOf<Long>()
            val runner = PcapImportRunner(store, staging, idFactory = { analysisID })
            val result = runner.import(
                source = BytesSource("capture.pcap", fixture, "application/vnd.tcpdump.pcap"),
                detailed = false,
                onProgress = { progress += it },
            )
            assertTrue(result is PcapImportResult.Success)
            val success = result as PcapImportResult.Success
            assertEquals(analysisID, success.analysisID)
            assertTrue(success.summary.packetCount >= 1)
            assertNotNull(store.read(analysisID))
            assertTrue(progress.isNotEmpty())
            assertTrue(staging.listFiles().orEmpty().none { it.name.endsWith(".part") })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun declaredOverLimitIsRefusedBeforeReading() {
        val root = Files.createTempDirectory("floe-artifact-limit").toFile()
        try {
            val runner = PcapImportRunner(PcapAnalysisStore(File(root, "pcap")), File(root, "staging"))
            val result = runner.import(LargeDeclaredSource(), detailed = false)
            assertEquals(PcapImportResult.Failure(PcapImportFailure.SOURCE_TOO_LARGE), result)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun unknownFormatAndCancellationLeaveNoStagingFile() {
        val root = Files.createTempDirectory("floe-artifact-bad").toFile()
        try {
            val staging = File(root, "staging")
            val runner = PcapImportRunner(PcapAnalysisStore(File(root, "pcap")), staging)
            val bad = runner.import(BytesSource("bad.bin", "not a capture".toByteArray()), detailed = false)
            assertEquals(PcapImportResult.Failure(PcapImportFailure.UNSUPPORTED_FORMAT), bad)
            val cancelled = runner.import(
                BytesSource("capture.pcap", fixture), detailed = false,
                cancellation = PcapCancellation { true },
            )
            assertEquals(PcapImportResult.Failure(PcapImportFailure.CANCELLED), cancelled)
            assertTrue(staging.listFiles().orEmpty().isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun unavailableSourceAndFullStoreAreTyped() {
        val root = Files.createTempDirectory("floe-artifact-fail").toFile()
        try {
            val runner = PcapImportRunner(PcapAnalysisStore(File(root, "pcap")), File(root, "staging"))
            assertEquals(
                PcapImportResult.Failure(PcapImportFailure.SOURCE_UNAVAILABLE),
                runner.import(ThrowingSource(), detailed = false),
            )
            val full = PcapImportRunner(
                PcapAnalysisStore(File(root, "pcap2")), File(root, "staging2"),
                maxStoredAnalyses = 0,
            )
            assertEquals(
                PcapImportResult.Failure(PcapImportFailure.STORE_FULL),
                full.import(BytesSource("capture.pcap", fixture), detailed = false),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    private fun pcapFixture(): ByteArray {
        val frame = ByteArray(14 + 20 + 8 + 4)
        frame[12] = 0x08; frame[13] = 0x00
        val ip = 14
        frame[ip] = 0x45
        frame[ip + 2] = 0x00; frame[ip + 3] = 32
        frame[ip + 8] = 64
        frame[ip + 9] = 17
        frame[ip + 12] = 10; frame[ip + 15] = 1
        frame[ip + 16] = 10; frame[ip + 19] = 2
        val udp = 34
        frame[udp] = 0x30; frame[udp + 1] = 0x39
        frame[udp + 2] = 0x00; frame[udp + 3] = 0x35
        frame[udp + 4] = 0x00; frame[udp + 5] = 12
        val output = java.io.ByteArrayOutputStream()
        output.write(byteArrayOf(0xD4.toByte(), 0xC3.toByte(), 0xB2.toByte(), 0xA1.toByte()))
        write16(output, 2); write16(output, 4)
        write32(output, 0); write32(output, 0); write32(output, 65_535); write32(output, 1)
        write32(output, 1_700_000_000L); write32(output, 0)
        write32(output, frame.size.toLong()); write32(output, frame.size.toLong())
        output.write(frame)
        return output.toByteArray()
    }

    private fun write16(output: java.io.ByteArrayOutputStream, value: Int) {
        output.write(value and 0xFF); output.write((value ushr 8) and 0xFF)
    }

    private fun write32(output: java.io.ByteArrayOutputStream, value: Long) {
        for (i in 0 until 4) output.write(((value ushr (i * 8)) and 0xFF).toInt())
    }

    private class BytesSource(
        override val displayName: String?,
        private val bytes: ByteArray,
        override val mimeType: String? = null,
    ) : PcapContentSource {
        override val declaredBytes: Long? get() = bytes.size.toLong()
        override fun openStream(): InputStream = ByteArrayInputStream(bytes)
    }

    private class LargeDeclaredSource : PcapContentSource {
        override val displayName: String? = "huge.pcap"
        override val mimeType: String? = null
        override val declaredBytes: Long? = 129L * 1024L * 1024L
        override fun openStream(): InputStream = throw AssertionError("must not be opened")
    }

    private class ThrowingSource : PcapContentSource {
        override val displayName: String? = "blocked.pcap"
        override val mimeType: String? = null
        override val declaredBytes: Long? = null
        override fun openStream(): InputStream = throw IOException("denied")
    }
}

class CoverageArtifactCoordinatorTest {
    private val sessionID = UUID.fromString("60000000-0000-4000-8000-000000000006").toString()

    @Test
    fun sampleUsesOneRealScanAndStoresThePoint() = runBlocking {
        val root = Files.createTempDirectory("floe-coverage-host").toFile()
        try {
            val store = CoverageSessionStore(File(root, "coverage"))
            val executor = FakeExecutor { request ->
                scanJson(
                    request.operationID, status = "ok", rssi = -51, cacheAgeMs = 1_500,
                    scanAccepted = true, updated = true,
                )
            }
            val coordinator = CoverageArtifactCoordinator(store, executor, { sessionID })
            val created = coordinator.createSession("Home")
            assertTrue(created is CoverageResult.Success)
            val request = CoverageSampleRequest(
                label = "Living room", x = 0.25, y = 0.75, probe = null,
            )
            val result = coordinator.sample(sessionID, request)
            assertTrue(result is CoverageResult.Success)
            val session = (result as CoverageResult.Success).session
            assertEquals(1, session.points.size)
            assertEquals(-51, session.points.single().rssiDbm)
            assertEquals(1_500L, session.points.single().scan.cachedAgeMs)
            assertEquals(0.25, session.points.single().x, 0.0)
            assertTrue(executor.requests.single().contains("\"refresh\":true"))
            val reopened = store.load(sessionID)
            assertEquals(1, reopened!!.points.size)
            assertEquals("Home", reopened.name)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun permissionDeniedPointIsKeptTruthfulAndSurfacesPermissions() = runBlocking {
        val root = Files.createTempDirectory("floe-coverage-permission").toFile()
        try {
            val store = CoverageSessionStore(File(root, "coverage"))
            val executor = FakeExecutor { request ->
                scanJson(
                    request.operationID, status = "permissionRequired", rssi = null,
                    missing = listOf("android.permission.ACCESS_FINE_LOCATION"),
                )
            }
            val coordinator = CoverageArtifactCoordinator(store, executor, { sessionID })
            coordinator.createSession("Home")
            val result = coordinator.sample(
                sessionID, CoverageSampleRequest(null, 0.5, 0.5, probe = null),
            )
            assertTrue(result is CoverageResult.Success)
            val success = result as CoverageResult.Success
            assertEquals(listOf("android.permission.ACCESS_FINE_LOCATION"), success.missingPermissions)
            assertEquals("permissionRequired", success.session.points.single().scan.status.wire)
            assertEquals(0, success.session.points.single().scan.accessPoints.size)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun optionalProbeRunsOnlyWhenRequestedAndFailureIsRecorded() = runBlocking {
        val root = Files.createTempDirectory("floe-coverage-probe").toFile()
        try {
            val store = CoverageSessionStore(File(root, "coverage"))
            var scans = 0
            val executor = FakeExecutor { request ->
                if (request.method == "network.wifiScan") {
                    scans++
                    scanJson(request.operationID, status = "ok", rssi = -62)
                } else {
                    pingJson(request.operationID, status = "ok", averageMs = 9.5)
                }
            }
            val coordinator = CoverageArtifactCoordinator(store, executor, { sessionID })
            coordinator.createSession("Home")
            val withoutProbe = coordinator.sample(
                sessionID, CoverageSampleRequest(null, 0.2, 0.2, probe = null),
            )
            assertEquals(1, scans)
            assertTrue(withoutProbe is CoverageResult.Success)
            assertNull((withoutProbe as CoverageResult.Success).session.points.single().probe)

            val withProbe = coordinator.sample(
                sessionID,
                CoverageSampleRequest(
                    "Desk", 0.6, 0.6,
                    CoverageProbeRequestUi(kind = "ping", host = "192.168.1.1"),
                ),
            )
            assertEquals(2, scans)
            assertTrue(withProbe is CoverageResult.Success)
            val point = (withProbe as CoverageResult.Success).session.points.last()
            assertEquals("ping", point.probe!!.kind)
            assertEquals(9.5, point.probe!!.latencyMs!!, 0.001)
            assertEquals(3, executor.requests.size)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun sessionCreationAndPointLimitsAreTyped() = runBlocking {
        val root = Files.createTempDirectory("floe-coverage-limits").toFile()
        try {
            val store = CoverageSessionStore(File(root, "coverage"))
            val coordinator = CoverageArtifactCoordinator(
                store, FakeExecutor { scanJson(UUID.randomUUID().toString(), "ok", -50) },
                { sessionID }, maxSessions = 0,
            )
            assertEquals(CoverageFailure.SESSION_LIMIT,
                (coordinator.createSession("Home") as CoverageResult.Failure).failure)
            assertFalse(store.list().isNotEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    private class FakeExecutor(
        private val responder: (Request) -> String,
    ) : CoverageCaptureExecutor {
        data class Request(val method: String, val operationID: String)

        val requests = mutableListOf<String>()
        override suspend fun execute(requestJson: String): String {
            requests += requestJson
            val root = JSONObject(requestJson)
            return responder(Request(root.getString("method"), root.getString("operationID")))
        }

        override fun cancel(operationID: String) = Unit
    }

    private fun scanJson(
        operationID: String,
        status: String,
        rssi: Int?,
        cacheAgeMs: Long? = 0,
        scanAccepted: Boolean? = true,
        updated: Boolean? = true,
        missing: List<String> = emptyList(),
    ): String {
        val accessPoints = JSONArray()
        if (rssi != null) {
            accessPoints.put(JSONObject()
                .put("ssid", "HomeLab").put("bssid", "AA:BB:CC:DD:EE:FF")
                .put("rssiDbm", rssi).put("frequencyMhz", 2437).put("channel", 6)
                .put("band", "2.4 GHz").put("ageMs", 1_000))
        }
        val observations = JSONObject()
            .put("refreshRequested", true)
            .put("accessPoints", accessPoints)
            .put("scanAccepted", scanAccepted)
        if (cacheAgeMs != null) observations.put("cacheAgeMs", cacheAgeMs)
        if (updated != null) observations.put("resultsUpdated", updated)
        if (scanAccepted == true && updated == true) observations.put("refreshOutcome", "updated")
        return JSONObject()
            .put("version", 1).put("source", "phone")
            .put("operationID", operationID).put("method", "network.wifiScan")
            .put("status", status).put("measuredAt", "2026-10-31T00:00:00Z")
            .put("observations", observations)
            .put("missingPermissions", JSONArray().apply { missing.forEach(::put) })
            .toString()
    }

    private fun pingJson(operationID: String, status: String, averageMs: Double): String =
        JSONObject()
            .put("version", 1).put("source", "phone")
            .put("operationID", operationID).put("method", "network.ping")
            .put("status", status).put("measuredAt", "2026-10-31T00:00:00Z")
            .put("target", "192.168.1.1")
            .put("observations", JSONObject().put("averageMs", averageMs))
            .toString()
}

class NetworkArtifactPumpTest {
    private val epoch = 7L
    private val taskID = java.util.UUID.fromString("76000000-0000-4000-8000-000000000007")
    private val runID = java.util.UUID.fromString("77000000-0000-4000-8000-000000000007")
    private val sessionID = java.util.UUID.fromString("78000000-0000-4000-8000-000000000008")

    @Test
    fun backgroundTaskWithoutUiHolderReadsOnlyExplicitlySharedArtifact() = runBlocking {
        val root = Files.createTempDirectory("floe-artifact-pump").toFile()
        try {
            val store = com.floe.android.core.networkmonitor.CoverageSessionStore(File(root, "coverage"))
            store.save(
                com.floe.android.core.networkmonitor.CoverageSession(
                    sessionID = sessionID.toString(),
                    name = "Background session",
                    createdAtEpochMillis = 1_700_000_000_000L,
                    updatedAtEpochMillis = 1_700_000_000_000L,
                    ownerTaskId = null,
                    floorplan = null,
                    points = emptyList(),
                    ownerWorkspaceId = null,
                    agentReadable = true,
                ),
            )
            val transport = FakeArtifactTransport(
                descriptor = JSONObject()
                    .put("operation", "networkArtifact.execute")
                    .put("epoch", epoch.toString())
                    .put("method", "network.coverageSummary")
                    .put("operationID", "79000000-0000-4000-8000-000000000009")
                    .put("taskID", taskID.toString())
                    .put("runID", runID.toString())
                    .put("payloadBytes", coverageRequestBytes().size)
                    .put("budgetMs", 15_000)
                    .put("workspace", "")
                    .toString().toByteArray(),
                payload = coverageRequestBytes(),
            )
            var observed: NetworkArtifactCaller? = null
            var principal: NetworkArtifactPrincipal? = null
            val access = NetworkArtifactAccess { p, caller ->
                principal = p
                observed = caller
                // No UI holder lookup: a valid background task/run + live pump
                // epoch + explicit user share is sufficient.
                p.agentReadable && caller.taskID == taskID.toString() &&
                    caller.runID == runID.toString() && caller.epoch == epoch
            }
            val scope = kotlinx.coroutines.CoroutineScope(
                kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO,
            )
            val pump = NetworkArtifactHostPump(
                scope = scope,
                ioDispatcher = kotlinx.coroutines.Dispatchers.IO,
                currentNativeEpoch = { epoch },
                pcapStore = com.floe.android.core.pcap.PcapAnalysisStore(File(root, "pcap")),
                coverageStore = store,
                transport = transport,
                access = access,
            )
            assertTrue(pump.start(epoch))
            val settled = kotlinx.coroutines.withTimeout(5_000) { transport.completed.await() }
            assertTrue(pump.stopAndJoin(epoch, 2_000))
            assertEquals(0, settled.first)
            assertEquals(sessionID.toString(), principal!!.artifactID)
            assertEquals(taskID.toString(), observed!!.taskID)
            assertEquals(runID.toString(), observed!!.runID)
            assertTrue(principal!!.agentReadable)
            assertTrue(settled.second.toString(Charsets.UTF_8).contains("\"status\":\"ok\""))
        } finally {
            root.deleteRecursively()
        }
    }

    private fun coverageRequestBytes(): ByteArray = JSONObject()
        .put("version", 1)
        .put("operationID", "79000000-0000-4000-8000-000000000009")
        .put("method", "network.coverageSummary")
        .put("arguments", JSONObject().put("sessionID", sessionID.toString()))
        .toString().toByteArray()

    private class FakeArtifactTransport(
        private val descriptor: ByteArray,
        private val payload: ByteArray,
    ) : NetworkArtifactNativeTransport {
        private var claimed = false
        val completed = kotlinx.coroutines.CompletableDeferred<Pair<Int, ByteArray>>()

        override fun bindEpoch(epoch: Long): Int = 0
        override fun next(timeoutMillis: Int): Long {
            if (claimed) return 0
            claimed = true
            return 1
        }
        override fun describe(claim: Long): ByteArray = descriptor
        override fun payload(claim: Long): ByteArray = payload
        override fun isLive(claim: Long): Int = 1
        override fun shouldStop(claim: Long): Int = 0
        override fun complete(claim: Long, status: Int, value: ByteArray): Int {
            completed.complete(status to value)
            return 0
        }
        override fun close(epoch: Long): Int = 0
        override fun stats(): ByteArray? = "{}".toByteArray()
        override fun readiness(): ByteArray? = "{}".toByteArray()
    }
}
