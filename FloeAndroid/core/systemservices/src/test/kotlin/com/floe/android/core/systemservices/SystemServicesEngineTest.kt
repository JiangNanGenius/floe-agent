// SPDX-License-Identifier: MPL-2.0
//
// C06 system-services engine tests with injected fakes. Authored source; NOT
// RUN by this lane. No real platform call participates.

package com.floe.android.core.systemservices

import java.time.Instant
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

private class FakeLocation : LocationService {
    var capabilityValue = LocationCapability(true, true, SystemPermission.GRANTED, true)
    var value = LocationFixRow(-33.86, 151.20, 8.0, Instant.parse("2026-01-01T00:00:00Z"), true, "gps")
    override fun capability(evidence: PermissionEvidence): LocationCapability = capabilityValue
    override suspend fun currentFix(timeoutMs: Long): LocationFixRow = value
}

private class FakeContacts : ContactsService {
    var capabilityValue = ContactsCapability(true, SystemPermission.GRANTED)
    var rows: List<ContactRecordRow> = emptyList()
    var truncated = false
    override fun capability(evidence: PermissionEvidence): ContactsCapability = capabilityValue
    override suspend fun scan(query: String?, field: ContactField): Pair<List<ContactRecordRow>, Boolean> =
        rows to truncated
}

private class FakeNfc : NfcService {
    var capabilityValue = NfcCapability(true, true)
    var value = NfcReadRow(emptyList(), 0, false, listOf("Ndef"), false, 1)
    override fun capability(): NfcCapability = capabilityValue
    override suspend fun read(
        activity: android.app.Activity?,
        timeoutSeconds: Int,
    ): NfcReadRow = value
}

private class FakeHealth : HealthService {
    var capabilityValue = HealthCapability(HealthProviderStatus.AVAILABLE, setOf("steps"))
    override suspend fun capability(): HealthCapability = capabilityValue
    override suspend fun samples(
        metric: HealthMetric,
        start: Instant,
        end: Instant,
        limit: Int,
        pageToken: String?,
    ): HealthPageRow = HealthPageRow(emptyList(), null, 0, false)
    override suspend fun aggregate(
        metric: HealthMetric,
        aggregation: HealthAggregation,
        start: Instant,
        end: Instant,
    ): HealthAggregateRow = HealthAggregateRow(
        metric.wire, aggregation.wire, 1.0, metric.unit, 1, start, end, null,
    )
}

class SystemServicesEngineTest {
    private fun engine(): Pair<SystemServicesEngine, Triple<FakeLocation, FakeContacts, FakeNfc>> {
        val location = FakeLocation()
        val contacts = FakeContacts()
        val nfc = FakeNfc()
        val health = FakeHealth()
        return SystemServicesEngine(location, contacts, nfc, health) to Triple(location, contacts, nfc)
    }

    @Test
    fun contactScanKeepsATaskOwnedSnapshotAndPagesIt() = runBlocking {
        val (engine, fakes) = engine()
        val contacts = fakes.second
        contacts.rows = (0 until 150).map { index ->
            ContactRecordRow(
                id = index.toString(),
                displayName = "Contact $index",
                organization = "",
                phones = emptyList(),
                emails = emptyList(),
            )
        }
        val first = engine.contactsScan(null, null, null, 0, 100)
        assertEquals(100, first.rows.size)
        assertEquals(150, first.totalCount)
        assertTrue(first.nextOffset != null)
        val second = engine.contactsScan(null, null, first.scanToken, first.nextOffset!!, 100)
        assertEquals(50, second.rows.size)
        assertEquals(null, second.nextOffset)
        assertEquals(first.scanToken, second.scanToken)
        assertFalse(second.truncated)
    }

    @Test
    fun contactScanIsTruncatedAtTheCap() = runBlocking {
        val (engine, fakes) = engine()
        fakes.second.rows = (0 until 620).map { index ->
            ContactRecordRow("$index", "Contact $index", "", emptyList(), emptyList())
        }
        val page = engine.contactsScan(null, null, null, 0, 50)
        assertEquals(500, page.totalCount)
        assertTrue(page.truncated)
    }

    @Test
    fun unknownContactSnapshotIsAnHonestExpiredCursor() = runBlocking {
        val (engine, _) = engine()
        try {
            engine.contactsScan(null, null, "missing", 0, 50)
            fail("an unknown snapshot must not invent rows")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.CURSOR_EXPIRED, failure.code)
        }
    }

    @Test
    fun locationPermissionAndServicesAreDistinct() = runBlocking {
        val (engine, fakes) = engine()
        val location = fakes.first
        location.capabilityValue = LocationCapability(true, true, SystemPermission.NOT_DETERMINED, false)
        try {
            engine.locationFix()
            fail("unanswered permission must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.PERMISSION_NOT_DETERMINED, failure.code)
        }
        location.capabilityValue = LocationCapability(true, false, SystemPermission.GRANTED, true)
        try {
            engine.locationFix()
            fail("disabled services must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.LOCATION_SERVICES_DISABLED, failure.code)
        }
        location.capabilityValue = LocationCapability(true, true, SystemPermission.GRANTED, false)
        assertEquals(-33.86, engine.locationFix().latitude, 0.0001)
    }

    @Test
    fun nfcHardwareDisabledAndReadStatesAreDistinct() = runBlocking {
        val (engine, fakes) = engine()
        val nfc = fakes.third
        nfc.capabilityValue = NfcCapability(false, false)
        try {
            engine.nfcRead(null, 20)
            fail("absent hardware must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.NFC_HARDWARE_UNAVAILABLE, failure.code)
        }
        nfc.capabilityValue = NfcCapability(true, false)
        try {
            engine.nfcRead(null, 20)
            fail("disabled NFC must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.NFC_DISABLED, failure.code)
        }
        nfc.capabilityValue = NfcCapability(true, true)
        try {
            engine.nfcRead(null, 3)
            fail("short timeout must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
        assertEquals(0, engine.nfcRead(null, 20).rawBytes)
    }

    @Test
    fun healthRequiresProviderAndGranularMetricPermission() = runBlocking {
        val (engine, _) = engine()
        val start = Instant.parse("2026-01-01T00:00:00Z")
        val end = Instant.parse("2026-01-08T00:00:00Z")
        try {
            engine.healthSamples(HealthMetric.HEART_RATE, start, end, 50, null)
            fail("ungranted metric must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.HEALTH_PERMISSION_DENIED, failure.code)
        }
        try {
            engine.healthSamples(HealthMetric.ACTIVITY_SUMMARY, start, end, 50, null)
            fail("activity summary has no Android equivalent")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.HEALTH_UNSUPPORTED_METRIC, failure.code)
        }
    }

    @Test
    fun capabilitiesCombineRealPlatformStates() = runBlocking {
        val (engine, fakes) = engine()
        fakes.first.capabilityValue = LocationCapability(true, true, SystemPermission.GRANTED, false)
        fakes.second.capabilityValue = ContactsCapability(true, SystemPermission.DENIED)
        fakes.third.capabilityValue = NfcCapability(true, true)
        val snapshot = engine.capabilities(
            foreground = true,
            revision = 5,
            evidence = PermissionEvidence(locationRequested = true, contactsRequested = true),
        )
        assertEquals(5, snapshot.revision)
        assertTrue(snapshot.location.precise.not())
        assertEquals(SystemPermission.DENIED, snapshot.contacts.permission)
        assertTrue(snapshot.nfc.enabled)
        assertEquals(HealthProviderStatus.AVAILABLE, snapshot.health.providerStatus)
    }
}
