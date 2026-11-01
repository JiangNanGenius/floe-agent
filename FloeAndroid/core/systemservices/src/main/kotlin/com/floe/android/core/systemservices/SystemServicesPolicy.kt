// SPDX-License-Identifier: MPL-2.0
//
// Pure validation/rules for C06 system services. No Android framework object
// is touched here, so JVM tests can exercise the exact bounds, literal LIKE
// escaping and permission/aggregation decisions without a device.

package com.floe.android.core.systemservices

import java.time.Duration
import java.time.Instant

enum class ContactField(val wire: String) {
    ANY("any"),
    NAME("name"),
    ORGANIZATION("organization"),
    PHONE("phone"),
    EMAIL("email"),
    ;

    companion object {
        fun parse(raw: String?): ContactField? = entries.firstOrNull { it.wire == (raw?.trim() ?: "any") }
    }
}

data class ContactQueryPlan(
    val query: String?,
    val field: ContactField,
    val limit: Int,
    val offset: Int,
)

data class HealthQueryPlan(
    val metric: HealthMetric,
    val mode: HealthMode,
    val aggregation: HealthAggregation?,
    val start: Instant,
    val end: Instant,
    val limit: Int,
)

object SystemServicesPolicy {
    // MARK: Contacts

    fun contactPlan(
        query: String?,
        field: String?,
        limit: Int,
        offset: Int,
    ): ContactQueryPlan {
        val literal = query?.trim()?.takeIf { it.isNotEmpty() }
        if (literal != null) {
            if (literal.length > SystemServicesBounds.MAX_CONTACT_QUERY_CHARACTERS ||
                literal.toByteArray(Charsets.UTF_8).size > SystemServicesBounds.MAX_CONTACT_QUERY_BYTES
            ) {
                throw SystemServiceFailure(
                    SystemServiceFailureCode.INVALID_REQUEST,
                    "contact query is too long",
                )
            }
            if (literal.any { it.code < 0x20 || it.code == 0x7F }) {
                throw SystemServiceFailure(
                    SystemServiceFailureCode.INVALID_REQUEST,
                    "contact query contains control characters",
                )
            }
        }
        val parsedField = ContactField.parse(field) ?: throw SystemServiceFailure(
            SystemServiceFailureCode.INVALID_REQUEST,
            "invalid contact field",
        )
        if (literal == null && parsedField != ContactField.ANY) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "contact field requires a query",
            )
        }
        if (limit !in 1..SystemServicesBounds.MAX_CONTACT_PAGE) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "contact page limit is out of range",
            )
        }
        if (offset < 0 || offset > SystemServicesBounds.MAX_CONTACT_SCAN) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "contact offset is out of range",
            )
        }
        return ContactQueryPlan(literal, parsedField, limit, offset)
    }

    /** Escape a literal LIKE needle. Backslash, percent and underscore are
     *  escaped and the caller supplies `ESCAPE '\'`. There is no SQL or
     *  predicate interpolation from model text. */
    fun likePattern(query: String): String {
        val escaped = buildString(query.length + 4) {
            append('%')
            for (character in query) {
                when (character) {
                    '\\', '%', '_' -> {
                        append('\\')
                        append(character)
                    }
                    else -> append(character)
                }
            }
            append('%')
        }
        return escaped
    }

    /**
     * Build the Contacts selection for one literal query. Subqueries use the
     * ContactsContract Data mimetypes supplied by the caller; no column or
     * table name comes from the model.
     */
    fun contactsSelection(
        plan: ContactQueryPlan,
        nameColumn: String,
        contactIdColumn: String,
        dataContactIdColumn: String,
        dataMimeTypeColumn: String,
        dataValueColumn: String,
        phoneMimeType: String,
        emailMimeType: String,
        organizationMimeType: String,
    ): Pair<String?, Array<String>> {
        val query = plan.query ?: return null to emptyArray()
        val pattern = likePattern(query)
        val nameSelection = "$nameColumn LIKE ? ESCAPE '\\'"
        fun dataSelection(mimeType: String): String =
            "$contactIdColumn IN (SELECT $dataContactIdColumn FROM Data" +
                " WHERE $dataMimeTypeColumn = ? AND $dataValueColumn LIKE ? ESCAPE '\\')"
        return when (plan.field) {
            ContactField.ANY -> {
                val organization = dataSelection(organizationMimeType)
                val phone = dataSelection(phoneMimeType)
                val email = dataSelection(emailMimeType)
                "($nameSelection OR $organization OR $phone OR $email)" to arrayOf(
                    pattern,
                    organizationMimeType, pattern,
                    phoneMimeType, pattern,
                    emailMimeType, pattern,
                )
            }
            ContactField.NAME -> nameSelection to arrayOf(pattern)
            ContactField.ORGANIZATION -> dataSelection(organizationMimeType) to
                arrayOf(organizationMimeType, pattern)
            ContactField.PHONE -> dataSelection(phoneMimeType) to
                arrayOf(phoneMimeType, pattern)
            ContactField.EMAIL -> dataSelection(emailMimeType) to
                arrayOf(emailMimeType, pattern)
        }
    }

    fun sanitizeContactValue(raw: String?, limit: Int): String {
        if (raw.isNullOrEmpty()) return ""
        val filtered = buildString {
            for (character in raw) {
                if (character.code >= 0x20 && character.code != 0x7F) append(character)
                if (length >= limit) break
            }
        }
        return filtered.trim()
    }

    fun boundedContact(phones: List<String>, emails: List<String>): Pair<List<String>, List<String>> {
        fun clean(values: List<String>, limit: Int): List<String> = values
            .asSequence()
            .map { sanitizeContactValue(it, SystemServicesBounds.MAX_CONTACT_VALUE_CHARACTERS) }
            .filter { it.isNotEmpty() }
            .distinct()
            .take(limit)
            .toList()
        return clean(phones, SystemServicesBounds.MAX_CONTACT_PHONES) to
            clean(emails, SystemServicesBounds.MAX_CONTACT_EMAILS)
    }

    // MARK: Health

    fun healthPlan(
        metricWire: String?,
        modeWire: String?,
        aggregationWire: String?,
        startRaw: String?,
        endRaw: String?,
        limit: Int,
    ): HealthQueryPlan {
        val metric = HealthMetric.parse(metricWire) ?: throw SystemServiceFailure(
            SystemServiceFailureCode.INVALID_REQUEST,
            "invalid health metric",
        )
        if (!metric.supportedOnAndroid) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_UNSUPPORTED_METRIC,
                "activity summary is not available on Android Health Connect",
            )
        }
        val mode = HealthMode.parse(modeWire) ?: throw SystemServiceFailure(
            SystemServiceFailureCode.INVALID_REQUEST,
            "invalid health mode",
        )
        val aggregation = HealthAggregation.parse(aggregationWire)
        if (aggregationWire != null && aggregationWire.isNotBlank() && aggregation == null) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "invalid health aggregation",
            )
        }
        if (limit !in 1..SystemServicesBounds.MAX_HEALTH_PAGE) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "health page limit is out of range",
            )
        }
        val start = parseInstant(startRaw)
        val end = parseInstant(endRaw)
        if (!end.isAfter(start)) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "health range must be positive",
            )
        }
        val range = Duration.between(start, end)
        if (range > Duration.ofDays(SystemServicesBounds.MAX_HEALTH_RANGE_DAYS.toLong())) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "health range exceeds 366 days",
            )
        }
        if (mode == HealthMode.AGGREGATE) {
            if (aggregation == null) {
                throw SystemServiceFailure(
                    SystemServiceFailureCode.INVALID_REQUEST,
                    "health aggregation is required",
                )
            }
            if (!metric.quantity) {
                throw SystemServiceFailure(
                    SystemServiceFailureCode.HEALTH_QUERY_FAILED,
                    "aggregate is limited to quantity metrics",
                )
            }
            if (aggregation == HealthAggregation.SUM && !metric.supportsSum) {
                throw SystemServiceFailure(
                    SystemServiceFailureCode.INVALID_REQUEST,
                    "sum is limited to steps and active energy",
                )
            }
        }
        return HealthQueryPlan(metric, mode, aggregation, start, end, limit)
    }

    private fun parseInstant(raw: String?): Instant {
        val value = raw?.trim()
        if (value.isNullOrEmpty() || value.length > 64) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "invalid health date",
            )
        }
        return try {
            Instant.parse(value)
        } catch (_: Exception) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "invalid health date",
            )
        }
    }

    fun nfcTimeoutSeconds(raw: Int?): Int {
        val value = raw ?: SystemServicesBounds.DEFAULT_NFC_TIMEOUT_SECONDS
        if (value !in SystemServicesBounds.MIN_NFC_TIMEOUT_SECONDS..SystemServicesBounds.MAX_NFC_TIMEOUT_SECONDS) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "NFC timeout must be 5...55 seconds",
            )
        }
        return value
    }

    fun oxygenFraction(percent: Double): Double = (percent / 100.0).coerceIn(0.0, 1.0)
}
