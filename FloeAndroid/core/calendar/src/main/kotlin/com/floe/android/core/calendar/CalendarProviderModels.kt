// SPDX-License-Identifier: MPL-2.0
//
// C06 system-calendar provider values. These are trusted projections of real
// CalendarContract rows, never model paths or authorization.

package com.floe.android.core.calendar

data class CalendarSummaryRow(
    val id: Long,
    val displayName: String,
    val accountName: String,
    val accountType: String,
    val ownerAccount: String,
    val timeZone: String,
    val color: Int,
    val accessLevel: Int,
    val writable: Boolean,
    val visible: Boolean,
    val isPrimary: Boolean,
)

data class CalendarSnapshotRow(
    val providerAvailable: Boolean,
    val readGranted: Boolean,
    val writeGranted: Boolean,
    val calendars: List<CalendarSummaryRow>,
    val revision: Long,
)

data class CalendarEventRow(
    val eventID: Long,
    val calendarID: Long,
    val calendarName: String,
    val title: String,
    val startMillis: Long,
    val endMillis: Long,
    val allDay: Boolean,
    val timeZone: String,
    val location: String?,
    val notes: String?,
    val recurrence: String?,
    val originalInstanceTimeMillis: Long?,
    val status: Int?,
    val deleted: Boolean = false,
) {
    val recurring: Boolean get() = !recurrence.isNullOrBlank() || originalInstanceTimeMillis != null
    val detached: Boolean get() = originalInstanceTimeMillis != null
}

data class CalendarEventPageRow(
    val rows: List<CalendarEventRow>,
    val hasMore: Boolean,
    val totalCount: Int,
)

data class CalendarReceiptRow(
    val action: String,
    val eventID: Long,
    val calendarID: Long,
    val occurrenceStartMillis: Long?,
    val deleted: Boolean,
    val readbackVerified: Boolean,
    val verificationScope: String,
    val verifiedFields: List<String>,
)

data class CalendarCreateRequest(
    val calendarID: Long,
    val title: String,
    val startMillis: Long,
    val endMillis: Long,
    val allDay: Boolean,
    val timeZone: String,
    val notes: String?,
    val location: String?,
    val recurrence: String?,
)

data class CalendarPatch(
    val title: String? = null,
    val startMillis: Long? = null,
    val endMillis: Long? = null,
    val notes: String? = null,
    val location: String? = null,
    val allDay: Boolean? = null,
    val timeZone: String? = null,
    val recurrence: String? = null,
) {
    val isEmpty: Boolean
        get() = title == null && startMillis == null && endMillis == null && notes == null &&
            location == null && allDay == null && timeZone == null && recurrence == null
}

data class CalendarUpdateRequest(
    val eventID: Long,
    val occurrenceStartMillis: Long?,
    val span: String,
    val patch: CalendarPatch,
)

data class CalendarDeleteRequest(
    val eventID: Long,
    val occurrenceStartMillis: Long?,
    val span: String,
)

/** Closed provider failure vocabulary. Unknown platform exceptions are mapped
 *  to `providerRejected`/`providerUnavailable`, never to a success. */
enum class CalendarProviderFailureCode {
    PERMISSION_DENIED,
    WRITE_PERMISSION_DENIED,
    PROVIDER_ABSENT,
    NO_CALENDARS,
    NO_WRITABLE_CALENDAR,
    CALENDAR_MISSING,
    CALENDAR_NOT_WRITABLE,
    EVENT_NOT_FOUND,
    OCCURRENCE_NOT_FOUND,
    OCCURRENCE_AMBIGUOUS,
    STALE_OCCURRENCE,
    OCCURRENCE_REQUIRED,
    UNSUPPORTED_RECURRENCE,
    UNSUPPORTED_SPAN,
    INVALID_RANGE,
    INVALID_DATE,
    INVALID_TIMEZONE,
    INVALID_RECURRENCE,
    INVALID_FIELDS,
    INVALID_ALL_DAY,
    READBACK_MISMATCH,
    MUTATION_UNKNOWN,
    PROVIDER_REJECTED,
    PROVIDER_UNAVAILABLE,
    BUSY,
    INTERNAL_FAILURE,
}

class CalendarProviderFailure(
    val code: CalendarProviderFailureCode,
    override val message: String,
    val retryable: Boolean = false,
    val detail: String? = null,
) : Exception(message)

/** The trusted host lane only accepts this narrow provider surface. */
interface CalendarProviderBackend {
    fun snapshot(): CalendarSnapshotRow
    fun instances(
        startMillis: Long,
        endMillis: Long,
        calendarID: Long?,
        query: String?,
        limit: Int,
        offset: Int,
    ): CalendarEventPageRow
    fun event(eventID: Long): CalendarEventRow
    fun create(request: CalendarCreateRequest): CalendarReceiptRow
    fun update(request: CalendarUpdateRequest): CalendarReceiptRow
    fun delete(request: CalendarDeleteRequest): CalendarReceiptRow
}
