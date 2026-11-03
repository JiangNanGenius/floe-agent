// SPDX-License-Identifier: MPL-2.0
//
// Pure C06 system-services policy tests. Authored source; NOT RUN by this
// lane. No device, permission dialog, provider, radio or health record is
// touched.

package com.floe.android.core.systemservices

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SystemServicesPolicyTest {
    @Test
    fun contactQueryIsLiteralBoundedAndFieldScoped() {
        val plan = SystemServicesPolicy.contactPlan("Floe 100%_x", "organization", 25, 0)
        assertEquals("Floe 100%_x", plan.query)
        assertEquals(ContactField.ORGANIZATION, plan.field)
        assertEquals("%Floe 100\\%\\_x%", SystemServicesPolicy.likePattern("Floe 100%_x"))

        try {
            SystemServicesPolicy.contactPlan("a".repeat(121), null, 10, 0)
            fail("oversized query must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
        assertEquals(
            ContactField.NAME,
            SystemServicesPolicy.contactPlan("Floe", "name", 10, 0).field,
        )
        try {
            SystemServicesPolicy.contactPlan(null, "name", 10, 0)
            fail("field without a query must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
        try {
            SystemServicesPolicy.contactPlan(null, null, 101, 0)
            fail("limit above the page cap must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
    }

    @Test
    fun contactSelectionUsesParameterizedColumnsAndSubqueries() {
        val plan = SystemServicesPolicy.contactPlan("Floe", "phone", 10, 0)
        val (selection, args) = SystemServicesPolicy.contactsSelection(
            plan,
            nameColumn = "display_name",
            contactIdColumn = "_id",
            dataContactIdColumn = "contact_id",
            dataMimeTypeColumn = "mimetype",
            dataValueColumn = "data1",
            phoneMimeType = "vnd.android.cursor.item/phone_v2",
            emailMimeType = "vnd.android.cursor.item/email_v2",
            organizationMimeType = "vnd.android.cursor.item/organization",
        )
        assertTrue(selection!!.contains("data1 LIKE ? ESCAPE '\\'"))
        assertEquals(2, args.size)
        assertEquals("vnd.android.cursor.item/phone_v2", args[0])
        assertEquals("%Floe%", args[1])
        assertTrue(!selection.contains("Floe"))
    }

    @Test
    fun contactAnySelectionIncludesAllFourMatchFields() {
        val plan = SystemServicesPolicy.contactPlan("x", "any", 10, 0)
        val (selection, args) = SystemServicesPolicy.contactsSelection(
            plan,
            "display_name", "_id", "contact_id", "mimetype", "data1",
            "phone", "email", "organization",
        )
        assertTrue(selection!!.contains("display_name LIKE ?"))
        assertTrue(selection.contains("phone"))
        assertTrue(selection.contains("email"))
        assertTrue(selection.contains("organization"))
        assertEquals(7, args.size)
    }

    @Test
    fun contactValuesAreSanitizedAndBounded() {
        assertEquals("", SystemServicesPolicy.sanitizeContactValue(null, 10))
        assertEquals("ab", SystemServicesPolicy.sanitizeContactValue("a\u0000b", 10))
        val (phones, emails) = SystemServicesPolicy.boundedContact(
            listOf("1", "2", "3", "4", "1"),
            listOf("a@example.com", "b@example.com", "c@example.com", "d@example.com"),
        )
        assertEquals(listOf("1", "2", "3"), phones)
        assertEquals(3, emails.size)
    }

    @Test
    fun healthPlanEnforcesRangeMetricAndAggregationRules() {
        val start = "2026-01-01T00:00:00Z"
        val end = "2026-01-08T00:00:00Z"
        val plan = SystemServicesPolicy.healthPlan("steps", "samples", null, start, end, 50)
        assertEquals(HealthMetric.STEPS, plan.metric)
        assertEquals(HealthMode.SAMPLES, plan.mode)

        try {
            SystemServicesPolicy.healthPlan("activitySummary", "samples", null, start, end, 50)
            fail("activity summary has no Android equivalent")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.HEALTH_UNSUPPORTED_METRIC, failure.code)
        }
        try {
            SystemServicesPolicy.healthPlan("sleep", "aggregate", "average", start, end, 50)
            fail("sleep is not a quantity metric")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.HEALTH_QUERY_FAILED, failure.code)
        }
        try {
            SystemServicesPolicy.healthPlan("heartRate", "aggregate", "sum", start, end, 50)
            fail("sum is limited to steps/energy")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
        try {
            SystemServicesPolicy.healthPlan("steps", "samples", null, start, "2027-06-01T00:00:00Z", 50)
            fail("range above 366 days must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
        try {
            SystemServicesPolicy.healthPlan("steps", "aggregate", null, start, end, 50)
            fail("aggregate requires an aggregation")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
    }

    @Test
    fun nfcTimeoutAndOxygenConversionAreBounded() {
        assertEquals(20, SystemServicesPolicy.nfcTimeoutSeconds(null))
        assertEquals(5, SystemServicesPolicy.nfcTimeoutSeconds(5))
        try {
            SystemServicesPolicy.nfcTimeoutSeconds(56)
            fail("timeout above 55 must fail")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
        assertEquals(0.98, SystemServicesPolicy.oxygenFraction(98.0), 0.0001)
        assertEquals(0.0, SystemServicesPolicy.oxygenFraction(-5.0), 0.0001)
    }

    @Test
    fun instantParsingRejectsNonISOValues() {
        try {
            SystemServicesPolicy.healthPlan(
                "steps", "samples", null,
                "2026-01-01", "2026-01-02", 50,
            )
            fail("a date without time must be rejected")
        } catch (failure: SystemServiceFailure) {
            assertEquals(SystemServiceFailureCode.INVALID_REQUEST, failure.code)
        }
        assertEquals(
            Instant.parse("2026-01-01T00:00:00Z"),
            SystemServicesPolicy.healthPlan(
                "steps", "samples", null,
                "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", 50,
            ).start,
        )
    }
}
