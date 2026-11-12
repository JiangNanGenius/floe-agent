// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Model-facing projection regressions for bounded observations: generic
 * structural ids must not crowd out actual controls/text, equal values must
 * be distinguishable by real field ids, and a bounded summary must say that
 * omitted rows are not missing platform capability.
 */
class PhoneControlObservationProjectionTest {
    @Test
    fun structuralIdsDoNotCrowdOutDateAndTimeControls() {
        val structural = (0 until 40).map { index ->
            testNode(
                ref = "n$index",
                className = "android.widget.FrameLayout",
                viewId = "com.example.app:id/container_$index",
            )
        }
        val startDate = testNode(
            ref = "n40",
            className = "android.widget.TextView",
            viewId = "com.example.app:id/field_start_date",
            text = "2026-11-12",
            clickable = true,
        )
        val startTime = testNode(
            ref = "n41",
            className = "android.widget.TextView",
            viewId = "com.example.app:id/field_start_time",
            text = "09:00",
            clickable = true,
        )
        val endDate = testNode(
            ref = "n42",
            className = "android.widget.TextView",
            viewId = "com.example.app:id/field_end_date",
            text = "2026-11-12",
            clickable = true,
        )
        val endTime = testNode(
            ref = "n43",
            className = "android.widget.TextView",
            viewId = "com.example.app:id/field_end_time",
            text = "10:00",
            clickable = true,
        )
        val text = PhoneControlObservationText.summary(
            testObservation(structural + startDate + startTime + endDate + endTime),
        )
        assertTrue(text.length <= 1_800)
        assertFalse(text.contains("container_"))
        for (node in listOf(startDate, startTime, endDate, endTime)) {
            assertTrue("missing ${node.ref} in projection", text.contains("${node.ref}|"))
        }
        // Equal values keep their actual refs and are disambiguated by the
        // useful field id, never by a fabricated flag or clickability.
        assertTrue(text.contains("(field_start_date)"))
        assertTrue(text.contains("(field_end_date)"))
        assertTrue(text.contains("summary=4/44 rows"))
        assertTrue(text.contains("omitted rows are not absent controls"))
    }

    @Test
    fun readOnlyTextIsKeptWithItsRealDashFlag() {
        val label = testNode(
            ref = "n0",
            className = "android.widget.TextView",
            text = "Location",
        )
        val structural = testNode(
            ref = "n1",
            className = "android.widget.FrameLayout",
            viewId = "com.example.app:id/main_frame",
        )
        val text = PhoneControlObservationText.summary(
            testObservation(listOf(label, structural)),
        )
        assertTrue(text.contains("n0|TextView|-|Location"))
        assertFalse(text.contains("main_frame"))
        assertTrue(text.contains("summary=1/2 rows"))
    }

    @Test
    fun unlabelledActionsUsePlaceholdersAndKeepRealClickFlags() {
        val button = testNode(
            ref = "n0",
            className = "android.widget.ImageButton",
            viewId = "com.example.app:id/add",
            clickable = true,
        )
        val text = PhoneControlObservationText.summary(testObservation(listOf(button)))
        // The id may be a useful suffix in the future, but the row must not
        // pretend a non-clickable view is clickable or vice versa.
        assertTrue(text.contains("n0|ImageButton|c|"))
        assertTrue(text.contains("[button]"))
        assertFalse(text.contains("n0|ImageButton|-|"))
    }

    @Test
    fun boundedOverflowKeepsRealRefsAndSaysTheSummaryIsBounded() {
        val nodes = (0 until 60).map { index ->
            testNode(
                ref = "n$index",
                className = "android.widget.Button",
                text = "Item $index",
                clickable = true,
                insideScrollable = true,
            )
        }
        val text = PhoneControlObservationText.summary(testObservation(nodes))
        assertTrue(text.length <= 1_800)
        assertTrue(text.contains("moreActions"))
        assertTrue(text.contains("summary=24/60 rows"))
        assertTrue(text.contains("omitted rows are not absent controls"))
    }

    @Test
    fun equalFieldHintsSurviveTheCompactOverflowIndex() {
        val actions = (0 until 30).map { index ->
            testNode(
                ref = "n$index",
                className = "android.widget.Button",
                text = "Action $index",
                clickable = true,
                insideScrollable = true,
            )
        }
        val startDate = testNode(
            ref = "n30",
            className = "android.widget.TextView",
            viewId = "com.example.app:id/field_start_date",
            text = "2026-11-12",
            clickable = true,
            insideScrollable = true,
        )
        val endDate = testNode(
            ref = "n31",
            className = "android.widget.TextView",
            viewId = "com.example.app:id/field_end_date",
            text = "2026-11-12",
            clickable = true,
            insideScrollable = true,
        )
        val text = PhoneControlObservationText.summary(
            testObservation(actions + startDate + endDate),
        )
        assertTrue(text.length <= 1_800)
        assertTrue(text.contains("moreActions"))
        assertTrue(text.contains("n30|"))
        assertTrue(text.contains("n31|"))
        // The compact index puts the useful field id first, so equal values
        // remain distinguishable even when they do not fit a full row.
        assertTrue(text.contains("field_start_date"))
        assertTrue(text.contains("field_end_date"))
    }

    @Test
    fun protectedEditableFieldsStayFirstAndNeverExposeTheirContents() {
        val protectedInput = testNode(
            ref = "n0",
            className = "android.widget.EditText",
            viewId = "com.example.app:id/password",
            editable = true,
            password = true,
            redacted = true,
            text = "secret-value",
        )
        val ordinaryInput = testNode(
            ref = "n1",
            className = "android.widget.EditText",
            editable = true,
        )
        val text = PhoneControlObservationText.summary(
            testObservation(listOf(protectedInput, ordinaryInput)),
        )
        assertTrue(text.indexOf("n0|") < text.indexOf("n1|"))
        assertTrue(text.contains("n0|EditText|pe|[protected]"))
        assertTrue(text.contains("n1|EditText|e|[empty input]"))
        assertFalse(text.contains("secret-value"))
    }
}
