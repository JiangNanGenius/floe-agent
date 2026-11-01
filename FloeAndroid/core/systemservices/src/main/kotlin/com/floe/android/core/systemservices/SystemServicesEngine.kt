// SPDX-License-Identifier: MPL-2.0
//
// C06 system-services engine: one App-owned object that combines the real
// platform clients with bounded, task-owned contact snapshots. It never
// prompts, never writes, never starts a background service and never falls
// back to fake data.

package com.floe.android.core.systemservices

import android.app.Activity
import java.time.Instant
import java.util.UUID

interface LocationService {
    fun capability(evidence: PermissionEvidence): LocationCapability
    suspend fun currentFix(timeoutMs: Long = SystemServicesBounds.LOCATION_TIMEOUT_MS): LocationFixRow
}

interface ContactsService {
    fun capability(evidence: PermissionEvidence): ContactsCapability
    suspend fun scan(query: String?, field: ContactField): Pair<List<ContactRecordRow>, Boolean>
}

interface NfcService {
    fun capability(): NfcCapability
    suspend fun read(activity: Activity?, timeoutSeconds: Int): NfcReadRow
}

interface HealthService {
    suspend fun capability(): HealthCapability
    suspend fun samples(
        metric: HealthMetric,
        start: Instant,
        end: Instant,
        limit: Int,
        pageToken: String?,
    ): HealthPageRow
    suspend fun aggregate(
        metric: HealthMetric,
        aggregation: HealthAggregation,
        start: Instant,
        end: Instant,
    ): HealthAggregateRow
}

class SystemServicesEngine(
    private val locationService: LocationService,
    private val contactsService: ContactsService,
    private val nfcService: NfcService,
    private val healthService: HealthService,
) {
    private data class ContactSnapshot(
        val token: String,
        val rows: List<ContactRecordRow>,
        val truncated: Boolean,
        val createdAt: Long,
    )

    private val lock = Any()
    private val snapshots = LinkedHashMap<String, ContactSnapshot>()

    suspend fun capabilities(
        foreground: Boolean,
        revision: Long,
        evidence: PermissionEvidence,
    ): SystemAvailability = SystemAvailability(
        foreground = foreground,
        revision = revision,
        location = locationService.capability(evidence),
        contacts = contactsService.capability(evidence),
        nfc = nfcService.capability(),
        health = healthService.capability(),
    )

    suspend fun locationFix(): LocationFixRow {
        val capability = locationService.capability(PermissionEvidence(true, false))
        when (capability.permission) {
            SystemPermission.GRANTED -> Unit
            SystemPermission.NOT_DETERMINED -> throw SystemServiceFailure(
                SystemServiceFailureCode.PERMISSION_NOT_DETERMINED,
                "location permission has not been answered",
            )
            SystemPermission.DENIED -> throw SystemServiceFailure(
                SystemServiceFailureCode.PERMISSION_DENIED,
                "location permission is denied",
            )
            SystemPermission.RESTRICTED -> throw SystemServiceFailure(
                SystemServiceFailureCode.PERMISSION_RESTRICTED,
                "location permission is restricted",
            )
            SystemPermission.UNAVAILABLE -> throw SystemServiceFailure(
                SystemServiceFailureCode.LOCATION_UNAVAILABLE,
                "location is unavailable",
            )
        }
        if (!capability.servicesEnabled) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.LOCATION_SERVICES_DISABLED,
                "location services are disabled",
            )
        }
        return locationService.currentFix()
    }

    suspend fun contactsScan(
        query: String?,
        field: String?,
        scanToken: String?,
        offset: Int,
        limit: Int,
    ): ContactScanPageRow {
        if (scanToken != null) {
            val snapshot = synchronized(lock) {
                pruneContactsLocked()
                snapshots[scanToken]
            } ?: throw SystemServiceFailure(
                SystemServiceFailureCode.CURSOR_EXPIRED,
                "the contact scan snapshot expired",
                retryable = true,
            )
            return page(snapshot, offset, limit)
        }
        val parsed = ContactField.parse(field) ?: throw SystemServiceFailure(
            SystemServiceFailureCode.INVALID_REQUEST,
            "invalid contact field",
        )
        SystemServicesPolicy.contactPlan(query, parsed.wire, limit, offset)
        val (rows, truncated) = contactsService.scan(query, parsed)
        val token = UUID.randomUUID().toString()
        val snapshot = ContactSnapshot(
            token = token,
            rows = rows.take(SystemServicesBounds.MAX_CONTACT_SCAN),
            truncated = truncated || rows.size > SystemServicesBounds.MAX_CONTACT_SCAN,
            createdAt = System.currentTimeMillis(),
        )
        synchronized(lock) {
            pruneContactsLocked()
            while (snapshots.size >= SystemServicesBounds.MAX_CONTACTS_SNAPSHOTS) {
                val oldest = snapshots.keys.firstOrNull() ?: break
                snapshots.remove(oldest)
            }
            snapshots[token] = snapshot
        }
        return page(snapshot, offset, limit)
    }

    suspend fun nfcRead(
        activity: Activity?,
        timeoutSeconds: Int?,
    ): NfcReadRow {
        val timeout = SystemServicesPolicy.nfcTimeoutSeconds(timeoutSeconds)
        val capability = nfcService.capability()
        if (!capability.hardwareAvailable) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.NFC_HARDWARE_UNAVAILABLE,
                "this device has no NFC adapter",
            )
        }
        if (!capability.enabled) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.NFC_DISABLED,
                "NFC is disabled",
            )
        }
        return nfcService.read(activity, timeout)
    }

    suspend fun healthSamples(
        metric: HealthMetric,
        start: Instant,
        end: Instant,
        limit: Int,
        pageToken: String?,
    ): HealthPageRow {
        requireHealth(metric)
        return healthService.samples(
            metric,
            start,
            end,
            limit.coerceIn(1, SystemServicesBounds.MAX_HEALTH_PAGE),
            pageToken,
        )
    }

    suspend fun healthAggregate(
        metric: HealthMetric,
        aggregation: HealthAggregation,
        start: Instant,
        end: Instant,
    ): HealthAggregateRow {
        requireHealth(metric)
        return healthService.aggregate(metric, aggregation, start, end)
    }

    private suspend fun requireHealth(metric: HealthMetric) {
        if (!metric.supportedOnAndroid) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_UNSUPPORTED_METRIC,
                "activity summary is not available on Android Health Connect",
            )
        }
        val capability = healthService.capability()
        when (capability.providerStatus) {
            HealthProviderStatus.AVAILABLE -> Unit
            HealthProviderStatus.UPDATE_REQUIRED -> throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_PROVIDER_UPDATE_REQUIRED,
                "Health Connect needs an update",
            )
            HealthProviderStatus.UNAVAILABLE -> throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_PROVIDER_ABSENT,
                "Health Connect is not available on this device",
            )
        }
        if (!capability.grantedMetrics.contains(metric.wire)) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_PERMISSION_DENIED,
                "health read permission is not granted for this metric",
                detail = "metric=${metric.wire}",
            )
        }
    }

    private fun page(snapshot: ContactSnapshot, offset: Int, limit: Int): ContactScanPageRow {
        if (offset < 0 || offset > snapshot.rows.size) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_CURSOR,
                "contact scan offset is out of range",
            )
        }
        val rowLimit = limit.coerceIn(1, SystemServicesBounds.MAX_CONTACT_PAGE)
        val upper = minOf(snapshot.rows.size, offset + rowLimit)
        val pageRows = if (offset >= upper) emptyList() else snapshot.rows.subList(offset, upper).toList()
        return ContactScanPageRow(
            scanToken = snapshot.token,
            rows = pageRows,
            totalCount = snapshot.rows.size,
            truncated = snapshot.truncated,
            nextOffset = if (upper < snapshot.rows.size) upper else null,
        )
    }

    private fun pruneContactsLocked() {
        val cutoff = System.currentTimeMillis() - SystemServicesBounds.CONTACTS_SNAPSHOT_TTL_MS
        val expired = snapshots.filterValues { it.createdAt < cutoff }.keys.toList()
        for (key in expired) snapshots.remove(key)
    }

    fun reset() {
        synchronized(lock) { snapshots.clear() }
    }
}
