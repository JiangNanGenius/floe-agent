// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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

    // ------------------------------------------------- hint + detail paging

    @Test
    fun distinctHintSurvivesWhenTextWouldHideIt() {
        // The real month header carries both the visible month/year text and a
        // distinct mode-switch hint. Taking only the first non-empty field hid
        // the actionable hint; both must now be visible.
        val header = testNode(
            ref = "n0",
            className = "android.widget.TextView",
            text = "November 2026",
            hintText = "Switch to year view",
            clickable = true,
        )
        val text = PhoneControlObservationText.summary(testObservation(listOf(header)))
        assertTrue(text.contains("November 2026"))
        assertTrue(text.contains("[hint:Switch to year view]"))
        assertTrue(text.length <= 1_800)
    }

    @Test
    fun aHintThatIsTheOnlyLabelIsNotDuplicatedAsSecondaryMetadata() {
        val field = testNode(
            ref = "n0",
            className = "android.widget.EditText",
            hintText = "Search events",
            editable = true,
        )
        val text = PhoneControlObservationText.summary(testObservation(listOf(field)))
        // The empty field has no value, so its hint is the primary label; it
        // must not be repeated as a second marker.
        assertTrue(text.contains("n0|EditText|e|Search events"))
        assertEquals(1, Regex("Search events").findAll(text).count())
    }

    @Test
    fun detailPageKeepsRelationshipsActionsRangeAndCurrentValue() {
        val nodes = listOf(
            testNode(ref = "n0", className = "android.widget.FrameLayout"),
            testNode(
                ref = "n1", parentRef = "n0", depth = 1,
                text = "November 2026",
                hintText = "Switch to year view",
                clickable = true,
            ),
            testNode(
                ref = "n2", parentRef = "n0", depth = 1,
                text = "Start date",
            ),
            testNode(
                ref = "n3", parentRef = "n0", depth = 1,
                className = "android.widget.EditText",
                viewId = "com.example.app:id/day",
                text = "12",
                hintText = "Day",
                editable = true,
                focusable = true,
                actions = setOf(
                    PhoneControlNodeAction.FOCUS,
                    PhoneControlNodeAction.IME_ENTER,
                    PhoneControlNodeAction.SET_TEXT,
                ),
                range = PhoneControlRangeInfo(min = 1f, max = 31f, current = 12f),
            ),
        )
        val page = PhoneControlObservationText.detail(testObservation(nodes), 0)
        assertEquals("observation-1", page.observationId)
        assertEquals(4, page.total)
        assertEquals(4, page.rows)
        assertNull(page.nextOffset)
        assertTrue(page.text.startsWith("observation=observation-1 page=com.example.app"))
        assertTrue(page.text.contains("hint=\"Switch to year view\""))
        assertTrue(page.text.contains("row=\"Start date\""))
        assertTrue(page.text.contains("rng=1..31@12"))
        assertTrue(page.text.contains("act=focus,ime,setText"))
        assertTrue(page.text.contains("id=day"))
        assertTrue(page.text.contains("lastPage=1"))
        assertTrue(page.text.contains("source=capturedObservation"))
        assertTrue(page.text.length <= 1_800)
    }

    @Test
    fun detailPagesAreBoundedAndContinueFromNextOffset() {
        val nodes = (0 until 80).map { index ->
            testNode(
                ref = "n$index",
                className = "android.widget.Button",
                text = "Item $index",
                clickable = true,
            )
        }
        val observation = testObservation(nodes)
        val first = PhoneControlObservationText.detail(observation, 0)
        assertTrue(first.text.length <= 1_800)
        assertTrue("first page should not claim the whole list", first.rows in 1 until 80)
        val next = first.nextOffset
        assertNotNull(next)
        assertTrue(next!! > 0)
        assertTrue(first.text.contains("nextOffset=$next"))

        val second = PhoneControlObservationText.detail(observation, next)
        assertEquals(observation.observationId, second.observationId)
        assertEquals(next, second.offset)
        assertTrue(second.text.length <= 1_800)
        assertTrue(second.rows > 0)

        var offset = 0
        var pages = 0
        while (true) {
            val page = PhoneControlObservationText.detail(observation, offset)
            assertTrue(page.text.length <= 1_800)
            pages += 1
            val following = page.nextOffset ?: break
            assertTrue(following > offset)
            offset = following
            assertTrue(pages < 100)
        }
        assertTrue(pages > 1)
        val last = PhoneControlObservationText.detail(observation, offset)
        assertTrue(last.text.contains("lastPage=1"))
    }

    @Test
    fun detailNeverExposesProtectedFieldContents() {
        val nodes = listOf(
            testNode(
                ref = "n0",
                className = "android.widget.EditText",
                text = "hunter2",
                contentDescription = "PIN 1234",
                hintText = "Password",
                editable = true,
                password = true,
            ),
        )
        val page = PhoneControlObservationText.detail(testObservation(nodes), 0)
        assertFalse(page.text.contains("hunter2"))
        assertFalse(page.text.contains("PIN 1234"))
        assertFalse(page.text.contains("Password"))
        assertTrue(page.text.contains("fields=protected"))
    }

    @Test
    fun truncationReasonsAreNamedNotJustABoolean() {
        val observation = testObservation(
            nodes = listOf(testNode(ref = "n0", text = "Label")),
            truncated = true,
            scannedNodeCount = 1200,
            scanLimited = true,
            timeLimited = true,
            selectionLimited = true,
            textLimited = true,
        )
        val summary = PhoneControlObservationText.summary(observation)
        assertTrue(summary.contains("truncated=scan,time,selection,text"))
        assertTrue(summary.contains("reasons=scan,time,selection,text"))
        val page = PhoneControlObservationText.detail(observation, 0)
        assertTrue(page.text.contains("truncated=scan,time,selection,text"))
    }
