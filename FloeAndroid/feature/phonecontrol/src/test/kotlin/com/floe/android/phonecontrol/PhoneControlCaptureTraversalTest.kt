// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Exercises the production level-order capture walk itself (not a hand-shaped
 * raw list). The shared fake tree exposes only the handle operations the
 * real walker uses, so these tests cover path construction, global budgets,
 * late chrome ordering, cancellation/obsolete handling and recycling.
 */
class PhoneControlCaptureTraversalTest {
    private data class WalkOutcome(
        val result: PhoneControlCaptureWalk.Result,
        val collector: TestCaptureCollector,
        val adapter: TestCaptureAdapter,
    )

    private fun walk(
        root: TestCaptureNode,
        maxNodes: Int = PhoneControlLimits.MAX_SCAN_NODES,
        maxDepth: Int = PhoneControlLimits.DEFAULT_DEPTH,
        deadline: Long = 1_000_000L,
        now: () -> Long = { 0L },
        isCancelled: () -> Boolean = { false },
        collector: TestCaptureCollector = TestCaptureCollector(),
    ): WalkOutcome {
        val adapter = TestCaptureAdapter()
        val result = PhoneControlCaptureWalk.walk(
            root = root,
            adapter = adapter,
            maxNodes = maxNodes,
            maxDepth = maxDepth,
            deadlineElapsedRealtimeMillis = deadline,
            nowElapsedRealtimeMillis = now,
            isCancelled = isCancelled,
            visit = collector::visit,
        )
        // Every live handle acquired by the walker is released exactly once.
        assertEquals(0, adapter.open)
        assertEquals(adapter.acquired, adapter.recycled)
        assertTrue("peak live handles ${adapter.peak}", adapter.peak <= maxDepth + 2)
        return WalkOutcome(result, collector, adapter)
    }

    @Test
    fun deepSkewedFormUnderTheGlobalCapIsFullyRead() {
        // Generic skewed form: a long spine reaches a ten-card list. The
        // second card contains a deep field chain while later siblings are
        // shallow. The old per-branch share starved this early deep branch.
        val deepLeaf = testCaptureNode(
            className = "android.widget.TextView",
            viewId = "com.example.app:id/field_start_time",
            text = "09:00",
            clickable = true,
        )
        val deepChain = testWrap(7, deepLeaf)
        val cards = (0 until 10).map { index ->
            when (index) {
                1 -> testCaptureNode(
                    children = listOf(
                        testCaptureNode(text = "filler"),
                        testCaptureNode(children = listOf(deepChain)),
                    ),
                )
                else -> testCaptureNode(
                    children = listOf(testCaptureNode(text = "card $index")),
                )
            }
        }
        val list = testCaptureNode(children = cards)
        val spine = testWrap(6, list)
        val grid = testCaptureNode(
            scrollable = true,
            children = (0 until 42).map { index ->
                testCaptureNode(
                    className = "android.widget.Button",
                    text = "day $index",
                    clickable = true,
                )
            },
        )
        val toolbar = testCaptureNode(
            children = listOf(
                testCaptureNode(
                    className = "android.widget.ImageButton",
                    contentDescription = "Search",
                    clickable = true,
                ),
            ),
        )
        val fab = testCaptureNode(
            className = "com.google.android.material.floatingactionbutton.FloatingActionButton",
            contentDescription = "Add",
            clickable = true,
        )
        val root = testCaptureNode(children = listOf(spine, grid, toolbar, fab))

        val outcome = walk(root)
        val expected = testCapturePaths(root)
        assertEquals(expected.size, outcome.result.visitedNodeCount)
        assertEquals(expected, outcome.result.visitedPaths.toSet())
        assertFalse(outcome.result.scanLimited)
        assertFalse(outcome.result.depthLimited)
        assertTrue(outcome.result.visitedPaths.any { it.size > 10 })

        val deepRaw = outcome.collector.raw.single {
            it.viewId == "com.example.app:id/field_start_time"
        }
        assertTrue(deepRaw.depth > 10)
        assertEquals("09:00", deepRaw.text)
        assertTrue(deepRaw.clickable)
        assertTrue(outcome.collector.raw.any { it.contentDescription == "Add" })
    }

    @Test
    fun wideGridStillReadsLateToolbarAndFabBeforeDeepContent() {
        val weeks = (0 until 10).map { week ->
            testCaptureNode(
                children = (0 until 7).map { day ->
                    testCaptureNode(
                        className = "android.widget.Button",
                        text = "w${week}d$day",
                        clickable = true,
                    )
                },
            )
        }
        val grid = testCaptureNode(scrollable = true, children = weeks)
        val toolbar = testCaptureNode(
            children = listOf(
                testCaptureNode(contentDescription = "Search", clickable = true),
            ),
        )
        val fab = testCaptureNode(contentDescription = "Add", clickable = true)
        val root = testCaptureNode(children = listOf(grid, toolbar, fab))

        val outcome = walk(root)
        assertEquals(testCapturePaths(root), outcome.result.visitedPaths.toSet())
        val visited = outcome.result.visitedPaths
        val firstCell = visited.indexOf(listOf(0, 0, 0))
        val lateFab = visited.indexOf(listOf(2))
        val toolbarButton = visited.indexOf(listOf(1, 0))
        assertTrue(firstCell >= 0)
        assertTrue(lateFab >= 0)
        assertTrue(toolbarButton >= 0)
        // The wide grid is first in tree order, but fixed chrome is visited
        // before the deep grid content.
        assertTrue(lateFab < firstCell)
        assertTrue(toolbarButton < firstCell)
    }

    @Test
    fun nodeCeilingStopsHonestlyAndRecycles() {
        val root = testCaptureNode(
            children = (0 until 30).map { testCaptureNode(text = "item $it") },
        )
        val outcome = walk(root, maxNodes = 10)
        assertEquals(10, outcome.result.visitedNodeCount)
        assertEquals(10, outcome.result.visitedPaths.size)
        assertTrue(outcome.result.scanLimited)
        assertFalse(outcome.result.timedOut)
        assertFalse(outcome.result.obsolete)
    }

    @Test
    fun exactNodeCeilingWithoutPendingWorkIsNotReportedAsTruncated() {
        val root = testCaptureNode(
            children = (0 until 9).map { testCaptureNode(text = "leaf $it") },
        )
        val outcome = walk(root, maxNodes = 10)
        assertEquals(10, outcome.result.visitedNodeCount)
        assertFalse(outcome.result.scanLimited)
    }

    @Test
    fun depthCeilingReportsDepthLimitAndStopsBelowIt() {
        var chain = testCaptureNode(text = "leaf")
        repeat(5) { chain = testCaptureNode(children = listOf(chain)) }
        val outcome = walk(chain, maxDepth = 3)
        assertEquals(4, outcome.result.visitedNodeCount)
        assertEquals(
            setOf(emptyList(), listOf(0), listOf(0, 0), listOf(0, 0, 0)),
            outcome.result.visitedPaths.toSet(),
        )
        assertTrue(outcome.result.depthLimited)
        assertFalse(outcome.result.scanLimited)
    }

    @Test
    fun cancellationStopsWithoutLeakingHandles() {
        val root = testCaptureNode(
            children = (0 until 20).map { testCaptureNode(text = "item $it") },
        )
        var visits = 0
        val collector = TestCaptureCollector().apply {
            onVisit = { visits += 1 }
        }
        val outcome = walk(
            root = root,
            isCancelled = { visits >= 5 },
            collector = collector,
        )
        assertTrue(outcome.result.cancelled)
        assertTrue(outcome.result.visitedNodeCount < 21)
    }

    @Test
    fun obsoleteVisitStopsTheCapture() {
        val root = testCaptureNode(
            children = (0 until 5).map { testCaptureNode(text = "item $it") },
        )
        val collector = TestCaptureCollector().apply { obsoleteAt = listOf(2) }
        val outcome = walk(root, collector = collector)
        assertTrue(outcome.result.obsolete)
        assertFalse(outcome.result.cancelled)
        assertEquals(3, outcome.result.visitedNodeCount)
        assertFalse(outcome.result.visitedPaths.contains(listOf(2)))
    }

    @Test
    fun timeBudgetStopsHonestly() {
        val root = testCaptureNode(
            children = (0 until 20).map { testCaptureNode(text = "item $it") },
        )
        var now = 0L
        val outcome = walk(
            root = root,
            deadline = 25L,
            now = { now += 10; now },
        )
        assertTrue(outcome.result.timedOut)
        assertTrue(outcome.result.scanLimited)
        assertTrue(outcome.result.visitedNodeCount < 21)
    }

    @Test
    fun nestedPickerAtDepthTwentyThreeIsReachableByTheDefaultRequest() {
        // Generic nested picker: the form's date/time leaves are at depth 17,
        // the picker header/prev/next controls are above depth 20, and day
        // cells reach depth 23. DEFAULT_DEPTH must reach MAX_DEPTH's bound.
        val prev = testCaptureNode(
            className = "android.widget.ImageButton",
            contentDescription = "Previous month",
            viewId = "com.example.app:id/picker_prev",
            clickable = true,
        )
        val month = testCaptureNode(
            className = "android.widget.TextView",
            text = "November 2026",
            viewId = "com.example.app:id/picker_month",
            clickable = true,
        )
        val next = testCaptureNode(
            className = "android.widget.ImageButton",
            contentDescription = "Next month",
            viewId = "com.example.app:id/picker_next",
            clickable = true,
        )
        val dayCells = (0 until 42).map { index ->
            testCaptureNode(
                className = "android.view.View",
                contentDescription = "day ${index + 1}",
                clickable = index == 11,
            )
        }
        val dayGrid = testCaptureNode(children = dayCells)
        val header = testCaptureNode(children = listOf(prev, month, next, dayGrid))
        val picker = testWrap(20, header)

        val startDate = testCaptureNode(
            className = "android.widget.TextView",
            text = "2026-11-12",
            viewId = "com.example.app:id/field_start_date",
            clickable = true,
        )
        val startTime = testCaptureNode(
            className = "android.widget.TextView",
            text = "09:00",
            viewId = "com.example.app:id/field_start_time",
            clickable = true,
        )
        val endDate = testCaptureNode(
            className = "android.widget.TextView",
            text = "2026-11-12",
            viewId = "com.example.app:id/field_end_date",
            clickable = true,
        )
        val endTime = testCaptureNode(
            className = "android.widget.TextView",
            text = "10:00",
            viewId = "com.example.app:id/field_end_time",
            clickable = true,
        )
        val formFields = testCaptureNode(
            children = listOf(startDate, startTime, endDate, endTime),
        )
        val form = testWrap(15, formFields)
        val root = testCaptureNode(children = listOf(picker, form))

        val maxDepth = testMaxDepth(root)
        assertTrue(maxDepth > 20)
        val request = PhoneControlObserveRequest()
        assertEquals(PhoneControlLimits.MAX_DEPTH, request.maxDepth)
        assertTrue(request.maxDepth >= maxDepth)

        val outcome = walk(root, maxDepth = request.maxDepth)
        assertEquals(testCapturePaths(root), outcome.result.visitedPaths.toSet())
        assertFalse(outcome.result.depthLimited)
        assertFalse(outcome.result.scanLimited)

        val shaped = PhoneControlTreeShaper.shape(
            raw = outcome.collector.raw,
            request = request,
            redactAllText = false,
            depthLimited = outcome.result.depthLimited,
            nodeLimited = outcome.result.scanLimited,
        )
        fun shapedNode(id: String): PhoneControlNode = shaped.nodes.single {
            it.viewId == "com.example.app:id/$id"
        }
        val prevNode = shapedNode("picker_prev")
        val nextNode = shapedNode("picker_next")
        val monthNode = shapedNode("picker_month")
        val startDateNode = shapedNode("field_start_date")
        val startTimeNode = shapedNode("field_start_time")
        val endDateNode = shapedNode("field_end_date")
        val endTimeNode = shapedNode("field_end_time")
        assertTrue(shaped.records[prevNode.ref]!!.path.size > 20)
        assertTrue(shaped.records[nextNode.ref]!!.path.size > 20)
        val dayNode = shaped.nodes.single { it.contentDescription == "day 12" }
        assertEquals(maxDepth, shaped.records[dayNode.ref]!!.path.size)
        assertFalse(shaped.truncated)
        assertFalse(shaped.maxDepthReached)

        val observation = testObservation(nodes = shaped.nodes).copy(
            scannedNodeCount = outcome.collector.raw.size,
            truncated = shaped.truncated,
            maxDepthReached = shaped.maxDepthReached,
        )
        val text = PhoneControlObservationText.summary(observation, maxNodes = 40)
        assertTrue(text.length <= 1_800)
        for (node in listOf(
            prevNode,
            nextNode,
            monthNode,
            startDateNode,
            startTimeNode,
            endDateNode,
            endTimeNode,
        )) {
            assertTrue("missing ${node.ref} in projection", text.contains("${node.ref}|"))
        }
        // Equal date values are distinguished by the real field id, while
        // distinct time values keep their own text labels.
        assertTrue(text.contains("(field_start_date)"))
        assertTrue(text.contains("(field_end_date)"))
    }
}
