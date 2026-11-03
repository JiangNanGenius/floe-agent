// SPDX-License-Identifier: MPL-2.0
//
// C06 Android system-services values. These are bounded projections of the
// REAL platform state: LocationManager, ContactsContract, the NFC adapter and
// Health Connect. None of these values is model-supplied authority.

package com.floe.android.core.systemservices

import java.time.Instant

/** Exact bounds shared with the Swift domain. */
object SystemServicesBounds {
    const val MAX_CONTACT_SCAN = 500
    const val MAX_CONTACT_PAGE = 50
    const val MAX_CONTACT_QUERY_CHARACTERS = 120
    const val MAX_CONTACT_QUERY_BYTES = 480
    const val MAX_CONTACT_PHONES = 3
    const val MAX_CONTACT_EMAILS = 3
    const val MAX_CONTACT_FIELD_CHARACTERS = 120
    const val MAX_CONTACT_VALUE_CHARACTERS = 320
    const val MAX_CONTACTS_SNAPSHOTS = 2
    const val CONTACTS_SNAPSHOT_TTL_MS = 10 * 60 * 1_000L

    const val MAX_HEALTH_RANGE_DAYS = 366
    const val MAX_HEALTH_PAGE = 50
    const val MAX_HEALTH_SCAN_ROWS = 1_000
    const val DEFAULT_HEALTH_PAGE = 50

    const val MIN_NFC_TIMEOUT_SECONDS = 5
    const val MAX_NFC_TIMEOUT_SECONDS = 55
    const val DEFAULT_NFC_TIMEOUT_SECONDS = 20
    const val MAX_NFC_RECORDS = 32
    const val MAX_NFC_BYTES = 32_768
    const val MAX_NFC_VALUE_CHARACTERS = 320

    const val LOCATION_TIMEOUT_MS = 15_000L
}

enum class SystemPermission(val wire: String) {
    NOT_DETERMINED("notDetermined"),
    GRANTED("granted"),
    DENIED("denied"),
    RESTRICTED("restricted"),
    UNAVAILABLE("unavailable"),
}

data class LocationCapability(
    val hardwareAvailable: Boolean,
    val servicesEnabled: Boolean,
    val permission: SystemPermission,
    val precise: Boolean,
)

data class ContactsCapability(
    val providerAvailable: Boolean,
    val permission: SystemPermission,
)

data class NfcCapability(
    val hardwareAvailable: Boolean,
    val enabled: Boolean,
)

enum class HealthProviderStatus(val wire: String) {
    AVAILABLE("available"),
    UPDATE_REQUIRED("updateRequired"),
    UNAVAILABLE("unavailable"),
}

data class HealthCapability(
    val providerStatus: HealthProviderStatus,
    val grantedMetrics: Set<String>,
)

data class PermissionEvidence(
    val locationRequested: Boolean,
    val contactsRequested: Boolean,
)

data class SystemAvailability(
    val foreground: Boolean,
    val revision: Long,
    val location: LocationCapability,
    val contacts: ContactsCapability,
    val nfc: NfcCapability,
    val health: HealthCapability,
)

/** Closed platform failure vocabulary. The App lane only executes these; it
 *  never invents a successful row for a denied permission or absent provider. */
enum class SystemServiceFailureCode(val wire: String) {
    PERMISSION_NOT_DETERMINED("permissionNotDetermined"),
    PERMISSION_DENIED("permissionDenied"),
    PERMISSION_RESTRICTED("permissionRestricted"),
    FOREGROUND_REQUIRED("foregroundRequired"),
    LOCATION_SERVICES_DISABLED("locationServicesDisabled"),
    LOCATION_UNAVAILABLE("locationUnavailable"),
    LOCATION_TIMED_OUT("locationTimedOut"),
    CONTACTS_PROVIDER_ABSENT("contactsProviderAbsent"),
    CONTACTS_UNAVAILABLE("contactsUnavailable"),
    CONTACTS_QUERY_FAILED("contactsQueryFailed"),
    NFC_HARDWARE_UNAVAILABLE("nfcHardwareUnavailable"),
    NFC_DISABLED("nfcDisabled"),
    NFC_BUSY("nfcBusy"),
    NFC_TAG_LOST("nfcTagLost"),
    NFC_UNSUPPORTED_TAG("nfcUnsupportedTag"),
    NFC_MALFORMED_TAG("nfcMalformedTag"),
    NFC_PAYLOAD_TOO_LARGE("nfcPayloadTooLarge"),
    HEALTH_PROVIDER_ABSENT("healthProviderAbsent"),
    HEALTH_PROVIDER_UPDATE_REQUIRED("healthProviderUpdateRequired"),
    HEALTH_PERMISSION_DENIED("healthPermissionDenied"),
    HEALTH_UNSUPPORTED_METRIC("healthUnsupportedMetric"),
    HEALTH_QUERY_FAILED("healthQueryFailed"),
    INVALID_REQUEST("invalidRequest"),
    INVALID_CURSOR("invalidCursor"),
    CURSOR_EXPIRED("cursorExpired"),
    BUSY("busy"),
    TIMED_OUT("timedOut"),
    CANCELLED("cancelled"),
    INTERNAL_FAILURE("internalFailure"),
}

class SystemServiceFailure(
    val code: SystemServiceFailureCode,
    override val message: String,
    val retryable: Boolean = false,
    val detail: String? = null,
) : Exception(message) {
    init {
        require(message.length <= 160) { "failure reason too long" }
        require((detail?.length ?: 0) <= 320) { "failure detail too long" }
    }
}

data class LocationFixRow(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Double,
    val timestamp: Instant,
    val precise: Boolean,
    val provider: String,
)

data class ContactRecordRow(
    val id: String,
    val displayName: String,
    val organization: String,
    val phones: List<String>,
    val emails: List<String>,
)

data class ContactScanPageRow(
    val scanToken: String,
    val rows: List<ContactRecordRow>,
    val totalCount: Int,
    val truncated: Boolean,
    val nextOffset: Int?,
)

data class NfcRecordRow(
    val index: Int,
    val tnf: Int,
    val type: String,
    val id: String,
    val kind: String,
    val value: String?,
    val payloadBytes: Int,
    val payloadSHA256: String,
    val truncated: Boolean,
)

data class NfcReadRow(
    val records: List<NfcRecordRow>,
    val rawBytes: Int,
    val writable: Boolean,
    val techList: List<String>,
    val truncated: Boolean,
    val elapsedMs: Long,
)

enum class HealthMetric(
    val wire: String,
    val unit: String,
    val quantity: Boolean,
    val supportsSum: Boolean,
    val supportedOnAndroid: Boolean = true,
) {
    STEPS("steps", "count", true, true),
    ACTIVE_ENERGY("activeEnergy", "kcal", true, true),
    HEART_RATE("heartRate", "count/min", true, false),
    RESTING_HEART_RATE("restingHeartRate", "count/min", true, false),
    SLEEP("sleep", "minutes", false, false),
    WORKOUTS("workouts", "minutes", false, false),
    ACTIVITY_SUMMARY("activitySummary", "none", false, false, supportedOnAndroid = false),
    BODY_MASS("bodyMass", "kg", true, false),
    OXYGEN_SATURATION("oxygenSaturation", "fraction", true, false),
    HEART_RATE_VARIABILITY("heartRateVariability", "ms", true, false),
    ;

    companion object {
        fun parse(raw: String?): HealthMetric? =
            entries.firstOrNull { it.wire == raw?.trim() }
    }
}

enum class HealthMode(val wire: String) {
    SAMPLES("samples"),
    AGGREGATE("aggregate"),
    ;

    companion object {
        fun parse(raw: String?): HealthMode? = entries.firstOrNull { it.wire == (raw?.trim() ?: "samples") }
    }
}

enum class HealthAggregation(val wire: String) {
    SUM("sum"),
    AVERAGE("average"),
    MINIMUM("minimum"),
    MAXIMUM("maximum"),
    MOST_RECENT("mostRecent"),
    ;

    companion object {
        fun parse(raw: String?): HealthAggregation? =
            entries.firstOrNull { it.wire == raw?.trim() }
    }
}

data class HealthSampleRowRow(
    val metric: String,
    val start: Instant,
    val end: Instant,
    val value: Double?,
    val unit: String,
    val detail: String?,
)

data class HealthPageRow(
    val rows: List<HealthSampleRowRow>,
    val nextPageToken: String?,
    val totalScanned: Int,
    val truncated: Boolean,
)

data class HealthAggregateRow(
    val metric: String,
    val aggregation: String,
    val value: Double?,
    val unit: String,
    val recordCount: Int,
    val start: Instant,
    val end: Instant,
    val detail: String?,
)
