// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Real platform action/range metadata stays authoritative and distinct from
 * the legacy booleans, and capture-bound reasons stay named rather than being
 * flattened into one ambiguous boolean.
 */
class PhoneControlActionMetadataTest {

    private fun shape(
        raw: List<PhoneControlRawNode>,
        maxNodes: Int = 100,
        timeLimited: Boolean = false,
        fieldLimited: Boolean = false,
    ): PhoneControlShaped = PhoneControlTreeShaper.shape(
        raw = raw,
        request = PhoneControlObserveRequest(maxNodes = maxNodes),
        redactAllText = false,
        depthLimited = false,
        nodeLimited = false,
        timeLimited = timeLimited,
        fieldLimited = fieldLimited,
    )

    @Test
    fun advertisedClickOutranksAndSurvivesBoundedSelection() {
        val labeled = (0 until 8).map { index ->
            testRawNode(path = listOf(index), text = "Label $index")
        }
        val advertisedClick = testRawNode(
            path = listOf(8),
            viewId = "com.example.app:id/action",
            clickable = false,
            actions = setOf(PhoneControlNodeAction.CLICK),
        )
        val withMetadata = shape(labeled + advertisedClick, maxNodes = 4)
        val advertised = withMetadata.nodes.singleOrNull {
            it.viewId == "com.example.app:id/action"
        } ?: throw AssertionError(
            "advertised ACTION_CLICK must rank as an actionable control",
        )
        assertTrue(advertised.advertises(PhoneControlNodeAction.CLICK))
        // The legacy flag is not fabricated: presentation says "declared by
        // the platform", the raw boolean stays false.
        assertFalse(advertised.clickable)

        val withoutMetadata = shape(
            labeled + advertisedClick.copy(actions = emptySet()),
            maxNodes = 4,
        )
        assertTrue(
            "without the real action the node is ordinary labelled content",
            withoutMetadata.nodes.none { it.viewId == "com.example.app:id/action" },
        )
    }

    @Test
    fun actionAndRangeMetadataSurviveShapingWithoutInference() {
        val shaped = shape(
            listOf(
                testRawNode(
                    path = emptyList(),
                    actions = setOf(
                        PhoneControlNodeAction.CLICK,
                        PhoneControlNodeAction.FOCUS,
                        PhoneControlNodeAction.IME_ENTER,
                        PhoneControlNodeAction.SCROLL_FORWARD,
                    ),
                    focusable = true,
                    focused = true,
                    range = PhoneControlRangeInfo(min = 1f, max = 31f, current = 12f),
                ),
            ),
        )
        val node = shaped.nodes.single()
        assertEquals(
            setOf(
                PhoneControlNodeAction.CLICK,
                PhoneControlNodeAction.FOCUS,
                PhoneControlNodeAction.IME_ENTER,
                PhoneControlNodeAction.SCROLL_FORWARD,
            ),
            node.actions,
        )
        assertTrue(node.focusable)
        assertTrue(node.focused)
        assertEquals(12f, node.range!!.current, 0.0f)
        assertTrue(shaped.records.getValue(node.ref).actions.contains(PhoneControlNodeAction.CLICK))
    }

    @Test
    fun invalidRangeIsNotPublished() {
        val shaped = shape(
            listOf(
                testRawNode(
                    path = emptyList(),
                    range = PhoneControlRangeInfo(min = 10f, max = 1f, current = 5f),
                ),
            ),
        )
        assertTrue(shaped.nodes.single().range == null)
    }

    @Test
    fun captureBoundsStayNamedAndSelectionIsReportedSeparately() {
        val raw = ArrayList<PhoneControlRawNode>()
        raw += testRawNode(path = emptyList())
        for (index in 0 until 20) {
            raw += testRawNode(path = listOf(index), text = "Item $index", clickable = true)
        }
        val shaped = shape(raw, maxNodes = 6, timeLimited = true, fieldLimited = true)
        assertTrue(shaped.truncated)
        assertTrue(shaped.timeLimited)
        assertTrue(shaped.textLimited)
        assertTrue(shaped.selectionLimited)
        assertFalse("the node budget was not reached", shaped.scanLimited)
    }

    @Test
    fun summaryFlagsDeclareRealCapabilitiesAndKeepBooleanHonesty() {
        val clickOnly = testNode(
            ref = "n0",
            className = "android.widget.ImageButton",
            text = "Search",
            clickable = false,
            actions = setOf(PhoneControlNodeAction.CLICK),
        )
        val input = testNode(
            ref = "n1",
            className = "android.widget.EditText",
            hintText = "Query",
            editable = true,
            focusable = true,
            actions = setOf(PhoneControlNodeAction.IME_ENTER),
        )
        val text = PhoneControlObservationText.summary(testObservation(listOf(clickOnly, input)))
        assertTrue(text.contains("n0|ImageButton|c|Search"))
        assertTrue(text.contains("n1|EditText|efi|Query"))
    }
}
