// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.nio.file.Files
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoverageModelsTest {
    private fun scan(
        capturedAt: Long = 1_700_000_000_000L,
        status: CoverageScanStatus = CoverageScanStatus.OK,
        rssi: Int? = -55,
        cacheAgeMs: Long? = 0,
        refresh: CoverageRefreshStatus = CoverageRefreshStatus.UPDATED,
        permission: Boolean = false,
    ): CoverageScanSnapshot = CoverageScanSnapshot(
        capturedAtEpochMillis = capturedAt,
        status = status,
        wifiEnabled = true,
        locationServicesEnabled = true,
        cachedAgeMs = cacheAgeMs,
        freshness = "fresh",
        refreshRequested = true,
        refreshStatus = refresh,
        scanAccepted = true,
        resultsUpdated = true,
        truncated = false,
        accessPoints = if (rssi == null) emptyList() else listOf(
            CoverageAccessPoint(
                ssid = "HomeLab", bssid = "AA:BB:CC:DD:EE:FF", rssiDbm = rssi,
                frequencyMhz = 2437, channel = 6, band = "2.4 GHz", widthMhz = 20,
                security = listOf("WPA3"), ageMs = 100,
                timestampMicros = 12_345,
            ),
        ),
        limitations = if (permission) listOf("Location services are disabled") else emptyList(),
        missingPermissions = if (permission) listOf("android.permission.ACCESS_FINE_LOCATION") else emptyList(),
    )

    private fun point(
        index: Int,
        x: Double = 0.5,
        y: Double = 0.5,
        rssi: Int? = -55,
        status: CoverageScanStatus = CoverageScanStatus.OK,
        capturedAt: Long = 1_700_000_000_000L,
        label: String? = "Living room",
    ): CoveragePoint = CoveragePoint(
        pointID = UUID.randomUUID().toString(),
        label = label,
        x = x,
        y = y,
        createdAtEpochMillis = capturedAt,
        scan = scan(capturedAt = capturedAt, status = status, rssi = rssi),
    )

    private fun session(vararg points: CoveragePoint): CoverageSession = CoverageSession(
        sessionID = "30000000-0000-4000-8000-000000000003",
        name = "Home survey",
        createdAtEpochMillis = 1_700_000_000_000L,
        updatedAtEpochMillis = 1_700_000_100_000L,
        ownerTaskId = null,
        floorplan = null,
        points = points.toList(),
    )

    @Test
    fun parserKeepsCachedAgeAndPermissionStatesTruthful() {
        val base = JSONObject()
            .put("version", 1).put("source", "phone")
            .put("operationID", UUID.randomUUID().toString())
            .put("method", "network.wifiScan").put("status", "permissionRequired")
            .put("measuredAt", "2026-10-31T00:00:00Z")
            .put("cacheAgeMs", 42_000)
            .put("observations", JSONObject()
                .put("refreshRequested", true)
                .put("cacheAgeMs", 42_000)
                .put("freshness", "aging")
                .put("locationServicesEnabled", false)
                .put("scanAccepted", false)
                .put("accessPoints", JSONArray()))
            .put("missingPermissions", JSONArray().put("android.permission.ACCESS_FINE_LOCATION"))
            .put("limitations", JSONArray().put("Location services are disabled"))
        val parsed = CoverageScanParser.parse(base.toString(), 1_700_000_000_000L)
        assertEquals(CoverageScanStatus.PERMISSION_REQUIRED, parsed.status)
        assertEquals(42_000L, parsed.cachedAgeMs)
        assertEquals(CoverageRefreshStatus.REFUSED, parsed.refreshStatus)
        assertEquals(false, parsed.locationServicesEnabled)
        assertEquals(1, parsed.missingPermissions.size)
        assertTrue(parsed.accessPoints.isEmpty())
    }

    @Test
    fun parserReadsRealAccessPointRows() {
        val raw = JSONObject()
            .put("version", 1).put("source", "phone")
            .put("operationID", UUID.randomUUID().toString())
            .put("method", "network.wifiScan").put("status", "ok")
            .put("measuredAt", "2026-10-31T00:00:00Z")
            .put("observations", JSONObject()
                .put("refreshRequested", true)
                .put("scanAccepted", true)
                .put("resultsUpdated", true)
                .put("refreshOutcome", "updated")
                .put("accessPoints", JSONArray().put(JSONObject()
                    .put("ssid", "HomeLab")
                    .put("bssid", "AA:BB:CC:DD:EE:FF")
                    .put("rssiDbm", -53)
                    .put("frequencyMhz", 5180)
                    .put("channel", 36)
                    .put("band", "5 GHz")
                    .put("widthMhz", 80)
                    .put("securityTypes", JSONArray().put("WPA3"))
                    .put("ageMs", 500))))
        val parsed = CoverageScanParser.parse(raw.toString(), 1_700_000_000_000L)
        assertEquals(CoverageScanStatus.OK, parsed.status)
        assertEquals(CoverageRefreshStatus.UPDATED, parsed.refreshStatus)
        assertEquals(1, parsed.accessPoints.size)
        assertEquals(-53, parsed.accessPoints.single().rssiDbm)
        assertEquals(36, parsed.accessPoints.single().channel)
        assertEquals(listOf("WPA3"), parsed.accessPoints.single().security)
        assertEquals(-53, parsed.bestSignalDbm)
    }

    @Test
    fun probeParserPreservesLatencyAndTypedFailures() {
        val ping = JSONObject()
            .put("version", 1).put("source", "phone")
            .put("operationID", UUID.randomUUID().toString())
            .put("method", "network.ping").put("status", "ok")
            .put("measuredAt", "2026-10-31T00:00:00Z")
            .put("target", "192.168.1.1")
            .put("observations", JSONObject().put("averageMs", 12.5))
        val parsed = CoverageProbeParser.parse("ping", ping.toString(), 1_700_000_000_000L)
        assertEquals("ok", parsed.status)
        assertEquals(12.5, parsed.latencyMs!!, 0.001)
        assertEquals("192.168.1.1", parsed.targetHost)

        val failed = JSONObject()
            .put("version", 1).put("source", "phone")
            .put("operationID", UUID.randomUUID().toString())
            .put("method", "network.tcpProbe").put("status", "error")
            .put("measuredAt", "2026-10-31T00:00:00Z")
            .put("observations", JSONObject().put("errorCode", "connectionRefused"))
        val error = CoverageProbeParser.parse("tcpProbe", failed.toString(), 1L)
        assertEquals("error", error.status)
        assertEquals("connectionRefused", error.errorCode)
        assertNull(error.latencyMs)
    }

    @Test
    fun gridLegendAndStaleAreDerivedFromActualPoints() {
        val points = listOf(
            point(0, x = 0.0, y = 0.0, rssi = -50),
            point(1, x = 0.1, y = 0.1, rssi = -75),
            point(2, x = 0.9, y = 0.9, rssi = null, status = CoverageScanStatus.PERMISSION_REQUIRED),
        )
        val session = session(*points.toTypedArray())
        val aggregate = CoverageMetrics.aggregate(session, 1_700_000_700_000L)
        assertEquals(3, aggregate.pointCount)
        assertEquals(1, aggregate.permissionRequiredCount)
        assertEquals(1, aggregate.noSignalCount)
        assertEquals(-75, aggregate.rssiMin)
        assertEquals(-50, aggregate.rssiMax)
        assertEquals(1, aggregate.legend.first { it.level == "strong" }.pointCount)
        assertEquals(1, aggregate.legend.first { it.level == "fair" }.pointCount)
        assertEquals(48, aggregate.grid.size)
        assertEquals(47, aggregate.unsampledCells)
        assertTrue(aggregate.estimatedCoveragePercent!! > 0.0)
        assertTrue(CoverageMetrics.stale(points[0].scan, 1_700_001_000_000L))
        assertEquals("strong", points[0].signalLevel)
        assertEquals(0.5, CoverageMetrics.normalizeCoordinate(0.5), 0.0)
        assertEquals(0.0, CoverageMetrics.normalizeCoordinate(-1.0), 0.0)
        assertEquals(1.0, CoverageMetrics.normalizeCoordinate(2.0), 0.0)
    }

    @Test
    fun exportsRedactIdentifiersAndToolReplyStaysWithinHeadroom() {
        val session = session(*List(120) { index ->
            point(index, x = (index % 10) / 10.0, y = ((index / 10) % 10) / 10.0,
                rssi = -40 - (index % 50), label = "Room ${index % 8}")
        }.toTypedArray())
        val redacted = CoverageReportRenderer.renderJson(session, false, 1_700_000_500_000L)
        assertFalse(redacted.contains("HomeLab"))
        assertFalse(redacted.contains("AA:BB:CC:DD:EE:FF"))
        val detailed = CoverageReportRenderer.renderJson(session, true, 1_700_000_500_000L)
        assertTrue(detailed.contains("HomeLab"))
        assertTrue(detailed.contains("AA:BB:CC:DD:EE:FF"))
        val tool = CoverageReportRenderer.renderToolSummary(session, 1_700_000_500_000L)
        assertTrue(tool.toByteArray(Charsets.UTF_8).size <= CoverageReportRenderer.MAX_TOOL_REPLY_BYTES)
        assertFalse(tool.contains("HomeLab"))
        assertFalse(tool.contains("AA:BB:CC:DD:EE:FF"))
        assertTrue(JSONObject(tool).getJSONArray("points").length() <= 60)
        val markdown = CoverageReportRenderer.renderMarkdown(session, false, 1_700_000_500_000L)
        assertTrue(markdown.startsWith("# Floe Wi-Fi coverage report"))
        assertFalse(markdown.contains("HomeLab"))
    }

    @Test
    fun legendRangesMatchClassifierAndMarkdownUsesTheSameBuckets() {
        val sampledSession = session(
            point(0, rssi = -60),
            point(1, rssi = -61),
            point(2, rssi = -70),
            point(3, rssi = -71),
            point(4, rssi = -80),
            point(5, rssi = -81),
        )
        val aggregate = CoverageMetrics.aggregate(sampledSession, 1_700_000_500_000L)
        val byLevel = aggregate.legend.associateBy { it.level }
        assertEquals(-60, byLevel["strong"]!!.minimumDbm)
        assertEquals(-70, byLevel["good"]!!.minimumDbm)
        assertEquals(-61, byLevel["good"]!!.maximumDbm)
        assertEquals(-80, byLevel["fair"]!!.minimumDbm)
        assertEquals(-71, byLevel["fair"]!!.maximumDbm)
        assertEquals(-81, byLevel["weak"]!!.maximumDbm)
        assertEquals(1, byLevel["strong"]!!.pointCount)
        assertEquals(2, byLevel["good"]!!.pointCount)
        assertEquals(2, byLevel["fair"]!!.pointCount)
        assertEquals(1, byLevel["weak"]!!.pointCount)

        val markdown = CoverageReportRenderer.renderMarkdown(
            sampledSession, false, 1_700_000_500_000L,
        )
        assertTrue(markdown.contains("good -70..-61"))
        assertTrue(markdown.contains("fair -80..-71"))
        assertTrue(markdown.contains("weak ≤ -81 dBm"))
        assertFalse(markdown.contains("good -69..-60"))

        val json = JSONObject(
            CoverageReportRenderer.renderJson(sampledSession, false, 1_700_000_500_000L),
        )
        val legend = json.getJSONObject("aggregate").getJSONArray("legend")
        assertEquals(-70, legend.getJSONObject(1).getInt("minimumDbm"))
        assertEquals(-61, legend.getJSONObject(1).getInt("maximumDbm"))
    }

    @Test
    fun codecRoundTripsOptionalFloorplanAndProbe() {
        val base = session(point(0))
        val withProbe = base.copy(points = listOf(base.points.single().copy(
            probe = CoverageProbeResult(
                kind = "tcpProbe", status = "ok", targetHost = "192.168.1.1",
                latencyMs = 4.5, measuredAtEpochMillis = 1_700_000_200_000L,
            ),
        )))
        val shared = withProbe.copy(agentReadable = true, ownerWorkspaceId = "ab".repeat(32))
        val json = CoverageSessionCodec.encode(shared)
        val decoded = CoverageSessionCodec.decode(json)
        assertEquals(withProbe.sessionID, decoded.sessionID)
        assertEquals(1, decoded.points.size)
        assertEquals("tcpProbe", decoded.points.single().probe!!.kind)
        assertEquals(4.5, decoded.points.single().probe!!.latencyMs!!, 0.001)
        assertTrue(decoded.agentReadable)
        assertEquals("ab".repeat(32), decoded.ownerWorkspaceId)
    }
}

class CoverageSessionStoreTest {
    private fun session(): CoverageSession = CoverageSession(
        sessionID = "40000000-0000-4000-8000-000000000004",
        name = "Store survey",
        createdAtEpochMillis = 1_700_000_000_000L,
        updatedAtEpochMillis = 1_700_000_000_000L,
        ownerTaskId = null,
        floorplan = null,
        points = emptyList(),
    )

    @Test
    fun savesLoadsListsAndDeletesAtomically() {
        val root = Files.createTempDirectory("floe-coverage-store").toFile()
        try {
            val store = CoverageSessionStore(root)
            val saved = store.save(session())
            assertTrue(saved.sessionFile.isFile)
            assertTrue(saved.manifestFile.isFile)
            val reopened = store.load(saved.sessionID)
            assertNotNull(reopened)
            assertEquals("Store survey", reopened!!.name)
            assertEquals(1, store.list().size)
            assertTrue(store.delete(saved.sessionID))
            assertNull(store.load(saved.sessionID))
            assertFalse(store.delete(saved.sessionID))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun storesAndVerifiesAnOptionalFloorplan() {
        val root = Files.createTempDirectory("floe-coverage-floorplan").toFile()
        try {
            val store = CoverageSessionStore(root)
            store.save(session())
            val image = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 1, 2, 3, 4)
            val updated = store.saveFloorplan(
                session().sessionID, image, "image/png", 640, 480,
            )
            assertEquals(8L, updated.floorplan!!.byteCount)
            assertEquals(640, updated.floorplan!!.width)
            val reopened = store.load(session().sessionID)!!
            assertNotNull(reopened.floorplan)
            assertArrayEqualsCompat(image, store.readFloorplan(session().sessionID))
            assertEquals(1, store.list().size)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun saveWithUppercaseIdentityPublishesOneLowercaseDirectory() {
        val root = Files.createTempDirectory("floe-coverage-store-canonical").toFile()
        try {
            val lower = "a5a18deb-cebf-4a17-97fd-0f6a30eb03bf"
            val upper = lower.uppercase(java.util.Locale.ROOT)
            val store = CoverageSessionStore(root)
            val saved = store.save(session().copy(sessionID = upper))
            assertEquals("coverage-$lower", saved.directory.name)
            assertEquals(lower, saved.sessionID)
            assertEquals(lower, saved.session.sessionID)
            val reopened = store.load(upper)
            assertNotNull(reopened)
            assertEquals(lower, reopened!!.sessionID)
            assertEquals("coverage-$lower", reopened.sessionFile.parentFile!!.name)
            assertEquals(lower, store.list().single().sessionID)
            assertTrue(store.delete(upper))
            assertNull(store.load(lower))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun readsAnUppercaseIdentityWrittenInTheLowercaseAppForm() {
        val root = Files.createTempDirectory("floe-coverage-store-uppercase-read").toFile()
        try {
            val lower = "a5a18deb-cebf-4a17-97fd-0f6a30eb03bf"
            val upper = lower.uppercase(java.util.Locale.ROOT)
            val store = CoverageSessionStore(root)
            store.save(session().copy(sessionID = lower))
            val reopened = store.load(upper)
            assertNotNull(reopened)
            assertEquals(lower, reopened!!.sessionID)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun ignoresCorruptOrMismatchedSessionFiles() {
        val root = Files.createTempDirectory("floe-coverage-corrupt").toFile()
        try {
            val store = CoverageSessionStore(root)
            val saved = store.save(session())
            saved.sessionFile.writeText("{}")
            assertNull(store.load(saved.sessionID))
            assertTrue(store.list().isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun assertArrayEqualsCompat(expected: ByteArray, actual: ByteArray?) {
        assertNotNull(actual)
        assertEquals(expected.size, actual!!.size)
        expected.indices.forEach { assertEquals(expected[it], actual[it]) }
    }
}
