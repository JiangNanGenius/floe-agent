// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Bounded-observation coverage regression for the N03 defect: the old
 * depth-first capture stopped at the first 100 raw nodes, and the compact
 * projection ranked only what had already been captured. A late FAB or
 * editable field after many grid/content nodes was therefore absent from both
 * stages. These fixtures use a generic calendar-shaped tree plus ordinary
 * app chrome; no real package label/id is special-cased.
 */
class PhoneControlObservationCoverageTest {
    private fun calendarTree(
        weeks: Int = 6,
        daysPerWeek: Int = 7,
        includeHiddenDecoys: Boolean = true,
    ): List<PhoneControlRawNode> {
        val raw = ArrayList<PhoneControlRawNode>()
        raw += testRawNode(path = emptyList(), className = "android.widget.FrameLayout")
        // Toolbar: fixed chrome outside a scrollable container.
        raw += testRawNode(path = listOf(0), className = "android.widget.Toolbar")
        raw += testRawNode(
            path = listOf(0, 0),
            className = "android.widget.ImageButton",
            contentDescription = "Search",
            clickable = true,
            bounds = PhoneControlBounds(900, 40, 1040, 180),
        )
        raw += testRawNode(
            path = listOf(0, 1),
            className = "android.widget.ImageButton",
            contentDescription = "More options",
            clickable = true,
            bounds = PhoneControlBounds(1040, 40, 1180, 180),
        )
        // Month grid inside one scrollable container.
        raw += testRawNode(
            path = listOf(1),
            className = "androidx.recyclerview.widget.RecyclerView",
            scrollable = true,
            bounds = PhoneControlBounds(0, 200, 1200, 1600),
        )
        for (week in 0 until weeks) {
            raw += testRawNode(
                path = listOf(1, week),
                className = "android.widget.LinearLayout",
                insideScrollable = true,
            )
            for (day in 0 until daysPerWeek) {
                val cellPath = listOf(1, week, day)
                raw += testRawNode(
                    path = cellPath,
                    className = "android.widget.Button",
                    text = "${week * 7 + day + 1}",
                    clickable = true,
                    insideScrollable = true,
                    bounds = PhoneControlBounds(day * 170, 200 + week * 220, (day + 1) * 170, 420 + week * 220),
                )
            }
        }
        if (includeHiddenDecoys) {
            for (index in 0 until 40) {
                raw += testRawNode(
                    path = listOf(1, weeks, index),
                    className = "android.view.View",
                    visible = false,
                    insideScrollable = true,
                )
            }
        }
        // Fixed-screen Add FAB and an editable field appear AFTER the grid in
        // tree order: the exact old loss shape.
        raw += testRawNode(
            path = listOf(2),
            className = "com.google.android.material.floatingactionbutton.FloatingActionButton",
            contentDescription = "Add",
            clickable = true,
            bounds = PhoneControlBounds(1020, 1480, 1180, 1640),
        )
        raw += testRawNode(
            path = listOf(3),
            className = "android.widget.EditText",
            hintText = "Search events",
            editable = true,
            bounds = PhoneControlBounds(40, 40, 880, 180),
        )
        return raw
    }

    private fun shape(
        raw: List<PhoneControlRawNode>,
        maxNodes: Int = 100,
        maxDepth: Int = 20,
        includeInvisible: Boolean = false,
    ): PhoneControlShaped = PhoneControlTreeShaper.shape(
        raw = raw,
        request = PhoneControlObserveRequest(
            maxNodes = maxNodes,
            maxDepth = maxDepth,
            includeInvisible = includeInvisible,
            textBudgetChars = PhoneControlLimits.DEFAULT_TEXT_BUDGET_CHARS,
        ),
        redactAllText = false,
        depthLimited = false,
        nodeLimited = false,
    )

    private fun observationOf(shaped: PhoneControlShaped): PhoneControlObservation =
        testObservation(nodes = shaped.nodes).copy(
            truncated = shaped.truncated,
            scannedNodeCount = shaped.nodes.size,
        )

    @Test
    fun lateFabToolbarAndEditableAfterAWholeMonthGridAreCapturedWithRealPaths() {
        val raw = calendarTree()
        val shaped = shape(raw)
        val fab = shaped.nodes.single { it.contentDescription == "Add" }
        val input = shaped.nodes.single { it.editable }
        val toolbar = shaped.nodes.single { it.contentDescription == "Search" }
        assertEquals(listOf(2), shaped.records[fab.ref]!!.path)
        assertEquals(listOf(3), shaped.records[input.ref]!!.path)
        assertEquals(listOf(0, 0), shaped.records[toolbar.ref]!!.path)
        assertTrue(fab.visible)
        assertTrue(fab.clickable)
        assertFalse(fab.insideScrollable)
        assertFalse(input.insideScrollable)
        // The 42 day cells keep their REAL paths, including the scroll flag.
        val days = shaped.nodes.filter { it.className == "android.widget.Button" }
        assertEquals(42, days.size)
        assertTrue(days.all { it.insideScrollable && it.visible && it.clickable })
        val firstDayPath = shaped.records[days.first().ref]!!.path
        assertEquals(listOf(1, 0, 0), firstDayPath)
        assertFalse(shaped.truncated)
    }

    @Test
    fun wideTreeKeepsLateControlsAndTheRealPathInsideTheNodeCeiling() {
        val raw = calendarTree(weeks = 10)
        val shaped = shape(raw, maxNodes = 64)
        assertEquals(64, shaped.nodes.size)
        assertTrue(shaped.truncated)
        val fab = shaped.nodes.single { it.contentDescription == "Add" }
        val input = shaped.nodes.single { it.editable }
        assertEquals(listOf(2), shaped.records[fab.ref]!!.path)
        assertEquals(listOf(3), shaped.records[input.ref]!!.path)
        // All actionables alone exceed the small ceiling; the selected subset
        // is still the actionable-first one, not the first 64 raw nodes.
        assertTrue(shaped.nodes.count {
            it.visible && it.enabled && (it.clickable || it.editable || it.scrollable)
        } >= 60)
    }

    @Test
    fun compactProjectionCoversMoreThanTwentyFourActionablesAndTheLateFab() {
        val shaped = shape(calendarTree(weeks = 9))
        val observation = observationOf(shaped)
        val text = PhoneControlObservationText.summary(observation, maxNodes = 40)
        assertTrue(text.length <= 1_850)
        assertTrue(text.contains("Add"))
        assertTrue(text.contains("Search events"))
        val actionableRefs = shaped.nodes.filter {
            it.visible && it.enabled && (it.clickable || it.editable || it.scrollable)
        }.map { it.ref }.toSet()
        val covered = actionableRefs.count { ref ->
            Regex("(^|[^0-9])" + Regex.escape(ref) + "(\\||\\|[ces]\\|)").containsMatchIn(text)
        }
        assertTrue("expected >24 actionable rows, saw $covered in:\n$text", covered > 24)
        assertTrue(text.contains("window=12"))
        assertTrue(text.contains("display=0"))
    }

    @Test
    fun fixedChromeWinsAStarvedCeilingOverInScrollContent() {
        val raw = calendarTree()
        val shaped = shape(raw, maxNodes = 4)
        assertEquals(4, shaped.nodes.size)
        assertTrue(shaped.nodes.any { it.contentDescription == "Add" })
        assertTrue(shaped.nodes.any { it.editable })
        assertTrue(shaped.truncated)
        // No fabricated path: each retained actionable has a real locator.
        for (node in shaped.nodes.filter { it.clickable || it.editable }) {
            val record = shaped.records[node.ref]
            assertNotNull(record)
            assertTrue(record!!.path.isNotEmpty() || node.editable)
        }
    }

    @Test
    fun selectionHonoursCountAndTextBudgetsWithoutInventingRefs() {
        val raw = ArrayList<PhoneControlRawNode>()
        raw += testRawNode(path = emptyList())
        for (index in 0 until 100) {
            raw += testRawNode(
                path = listOf(index),
                text = "Item $index ".repeat(20),
                clickable = true,
            )
        }
        val shaped = PhoneControlTreeShaper.shape(
            raw = raw,
            request = PhoneControlObserveRequest(
                maxNodes = 10,
                maxDepth = 20,
                includeInvisible = false,
                textBudgetChars = 50,
            ),
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        assertEquals(10, shaped.nodes.size)
        assertTrue(shaped.truncated)
        assertTrue(shaped.textChars <= 50)
        assertEquals(10, shaped.records.size)
        assertTrue(shaped.nodes.all { it.ref in shaped.records })
        // Each selected record still points at its real raw path.
        for (node in shaped.nodes) {
            val path = shaped.records[node.ref]!!.path
            val rawNode = raw.single { it.path == path }
            assertEquals(rawNode.clickable, shaped.records[node.ref]!!.clickable)
        }
    }

    @Test
    fun hiddenNodesAreCapturedOnlyWhenRequestedAndStayedVisibleFlagged() {
        val raw = calendarTree()
        val hiddenFab = testRawNode(
            path = listOf(4),
            contentDescription = "Hidden action",
            clickable = true,
            visible = false,
        )
        val visibleOnly = shape(raw + hiddenFab)
        assertTrue(visibleOnly.nodes.none { it.contentDescription == "Hidden action" })
        val withHidden = shape(raw + hiddenFab, includeInvisible = true)
        val hidden = withHidden.nodes.single { it.contentDescription == "Hidden action" }
        assertFalse(hidden.visible)
        assertTrue(hidden.clickable)
        assertEquals(listOf(4), withHidden.records[hidden.ref]!!.path)
        // Hidden nodes are captured for includeInvisible but ranked below all
        // visible actions; the projection never promotes them as actionable.
        val small = PhoneControlObservationText.summary(testObservation(nodes = listOf(hidden)))
        assertTrue(small.contains("Hidden action"))
        assertTrue(small.contains("|h|"))
    }

    @Test
    fun summaryHeaderCarriesActualWindowDisplayAndScanCounts() {
        val shaped = shape(calendarTree())
        val observation = observationOf(shaped).copy(
            scannedNodeCount = 640,
            omittedActionableCount = 3,
            truncated = true,
        )
        val text = PhoneControlObservationText.summary(observation)
        assertTrue(text.contains("window=12"))
        assertTrue(text.contains("display=0"))
        assertTrue(text.contains("nodes=${observation.nodes.size}/640"))
        assertTrue(text.contains("omittedActions=3"))
        assertTrue(text.contains("truncated"))
        assertTrue(text.length <= 1_850)
    }

    @Test
    fun protectedFieldRowsKeepTheirExactSafeProjection() {
        val nodes = listOf(
            testNode(
                ref = "n0", className = "android.widget.EditText",
                viewId = "com.example.app:id/password",
                editable = true, password = true, redacted = true,
            ),
            testNode(
                ref = "n1", className = "android.widget.EditText",
                viewId = "com.example.app:id/password2",
                editable = true, password = true, redacted = true, visible = false,
            ),
            testNode(ref = "n2", className = "android.widget.EditText", editable = true),
        )
        val text = PhoneControlObservationText.summary(testObservation(nodes))
        assertTrue(text.contains("n0|EditText|pe|[protected]"))
        assertTrue(text.contains("n1|EditText|hp|[protected]"))
        assertTrue(text.contains("n2|EditText|e|[empty input]"))
        assertTrue(text.contains("p=protected input"))
        assertTrue(text.contains("sensitiveText"))
    }

    @Test
    fun overflowStillAdvertisesRealLateActionableRefs() {
        // 60 in-scroll clickables plus chrome. The full rows cannot hold all
        // controls, so the compact index must keep genuine refs discoverable.
        val raw = ArrayList<PhoneControlRawNode>()
        raw += testRawNode(path = emptyList())
        raw += testRawNode(path = listOf(0), scrollable = true)
        for (index in 0 until 60) {
            raw += testRawNode(
                path = listOf(0, index),
                className = "android.widget.Button",
                text = "Item $index",
                clickable = true,
                insideScrollable = true,
            )
        }
        raw += testRawNode(
            path = listOf(1),
            className = "android.widget.ImageButton",
            contentDescription = "Compose",
            clickable = true,
        )
        val shaped = shape(raw, maxNodes = 100)
        val observation = observationOf(shaped)
        val text = PhoneControlObservationText.summary(observation, maxNodes = 40)
        assertTrue(text.length <= 1_850)
        assertTrue(text.contains("Compose"))
        assertTrue(text.contains("moreActions"))
        val fabRef = shaped.nodes.single { it.contentDescription == "Compose" }.ref
        assertTrue(text.contains(fabRef))
    }
}
