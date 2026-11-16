// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneControlSemanticIdentityTest {
    private fun identity(text: CharSequence?, description: CharSequence?) =
        PhoneControlSemanticIdentity.capture(
            visible = true, editable = false, password = false, redacted = false,
            text = { text }, description = { description },
        )

    @Test
    fun dateCellReusedAtSameLocationMustKeepItsOwnLabelAndDescription() {
        val before = identity("11", "Friday 11 December")
        assertEquals(before, identity("11", "Friday 11 December"))
        assertNotEquals(before, identity("12", "Friday 11 December"))
        assertNotEquals(before, identity("11", "Friday 18 December"))
        assertNotEquals(identity(null, null), identity("11", null))
        assertTrue(before.toString().contains("redacted"))
        assertNull(PhoneControlSemanticIdentity.validate(
            before, true, false, false, false, false,
            text = { "11" }, description = { "Friday 11 December" },
        ))
        assertEquals(PhoneControlDenial.STALE_OBSERVATION, PhoneControlSemanticIdentity.validate(
            before, true, false, false, false, false,
            text = { "12" }, description = { "Friday 12 December" },
        ))
    }

    @Test
    fun editablePasswordRedactedAndInvisibleNeverInvokeReaders() {
        fun skipped(visible: Boolean, editable: Boolean, password: Boolean, redacted: Boolean) =
            PhoneControlSemanticIdentity.capture(
                visible, editable, password, redacted,
                text = { error("text reader must not run") },
                description = { error("description reader must not run") },
            )
        assertNull(skipped(true, true, false, false))
        assertNull(skipped(true, false, true, false))
        assertNull(skipped(true, false, false, true))
        assertNull(skipped(false, false, false, false))
        val oldLabel = identity("11", null)
        // A previously non-editable node that becomes editable or protected
        // must fail without reading the newly sensitive surface.
        fun failClosed(editable: Boolean, password: Boolean, sensitiveInput: Boolean) =
            PhoneControlSemanticIdentity.validate(
                oldLabel, true, editable, password, false, sensitiveInput,
                text = { error("text reader must not run") },
                description = { error("description reader must not run") },
            )
        assertEquals(PhoneControlDenial.STALE_OBSERVATION, failClosed(true, false, false))
        assertEquals(PhoneControlDenial.STALE_OBSERVATION, failClosed(false, true, false))
        assertEquals(PhoneControlDenial.STALE_OBSERVATION, failClosed(false, false, true))
    }

    @Test
    fun liveCharSequenceReadIsBoundedAndFieldBoundariesAreDistinct() {
        val huge = object : CharSequence {
            override val length = 1_000_000
            override fun get(index: Int): Char = 'x'
            override fun subSequence(startIndex: Int, endIndex: Int): CharSequence {
                assertTrue(endIndex - startIndex <= PhoneControlLimits.MAX_FIELD_CHARS)
                return "x".repeat(endIndex - startIndex)
            }
            override fun toString(): String = error("unbounded read")
        }
        assertEquals(identity(huge, null), identity(huge, null))
        assertNotEquals(identity("ab", "c"), identity("a", "bc"))
    }

    @Test
    fun shaperKeepsIdentityOnlyForPositivelyEligibleOrdinaryNodes() {
        val nodes = listOf(
            testRawNode(listOf(0), text = "11", clickable = true).copy(semanticEligible = true),
            testRawNode(listOf(1), text = "private", editable = true).copy(semanticEligible = true),
            testRawNode(listOf(2), text = "secret", password = true).copy(semanticEligible = true),
            testRawNode(listOf(3), text = "unknown flag"),
        )
        val result = PhoneControlTreeShaper.shape(
            nodes, PhoneControlObserveRequest(), redactAllText = false,
            depthLimited = false, nodeLimited = false,
        )
        assertEquals(identity("11", null), result.records["n0"]?.semanticIdentity)
        assertNull(result.records["n1"]?.semanticIdentity)
        assertNull(result.records["n2"]?.semanticIdentity)
        assertNull(result.records["n3"]?.semanticIdentity)
    }
    @Test
    fun clickableParentTracksItsVisibleChildDate() {
        fun shaped(day: String) = PhoneControlTreeShaper.shape(
            listOf(
                testRawNode(listOf(0), clickable = true).copy(semanticEligible = true),
                testRawNode(listOf(0, 0), text = day).copy(semanticEligible = true),
            ),
            PhoneControlObserveRequest(), redactAllText = false,
            depthLimited = false, nodeLimited = false,
        ).records.getValue("n0")
        val before = shaped("11")
        val after = shaped("12")
        assertTrue(before.needsChildIdentity)
        assertEquals(listOf(0), before.semanticChildren.single().path)
        assertNotEquals(before.semanticChildren.single().identity, after.semanticChildren.single().identity)
        assertEquals(PhoneControlDenial.STALE_OBSERVATION, PhoneControlSemanticIdentity.validate(
            before.semanticChildren.single().identity, true, false, false, false, false,
            text = { "12" }, description = { null },
        ))
        val protected = PhoneControlTreeShaper.shape(
            listOf(
                testRawNode(listOf(0), clickable = true).copy(semanticEligible = true),
                testRawNode(listOf(0, 0), text = "private", editable = true).copy(semanticEligible = true),
            ), PhoneControlObserveRequest(), false, false, false,
        ).records.getValue("n0")
        assertTrue(protected.semanticChildren.isEmpty())
    }

    @Test
    fun unlabeledIconHasStructuralIdentityAndUnknownFlagsStayExplicit() {
        val result = PhoneControlTreeShaper.shape(
            listOf(
                testRawNode(listOf(0), clickable = true).copy(semanticEligible = true),
                testRawNode(listOf(0, 0)).copy(semanticEligible = true),
                testRawNode(listOf(1), clickable = true).copy(semanticFlagsUnavailable = true),
            ), PhoneControlObserveRequest(), false, false, false,
        )
        val icon = result.records.getValue("n0")
        assertTrue(icon.needsChildIdentity)
        assertEquals(listOf(0), icon.semanticChildren.single().path)
        assertEquals(identity(null, null), icon.semanticChildren.single().identity)
        assertTrue(result.records.getValue("n2").semanticFlagsUnavailable)
    }

    @Test
    fun ninthDateLabelIsPreferredAndPartialSubtreeIsMarkedIncomplete() {
        val parent = testRawNode(listOf(0), clickable = true).copy(semanticEligible = true)
        val blanks = (0..7).map { index ->
            testRawNode(listOf(0, index)).copy(semanticEligible = true)
        }
        val date = testRawNode(listOf(0, 8), text = "11").copy(semanticEligible = true)
        val shaped = PhoneControlTreeShaper.shape(
            listOf(parent) + blanks + date, PhoneControlObserveRequest(), false, false, false,
        ).records.getValue("n0")
        assertEquals(listOf(8), shaped.semanticChildren.single().path)
        assertEquals(identity("11", null), shaped.semanticChildren.single().identity)
        assertTrue(shaped.semanticChildrenIncomplete)
    }

    @Test
    fun unrelatedPageTruncationDoesNotBlockACompleteOwnLabel() {
        val record = PhoneControlTreeShaper.shape(
            listOf(testRawNode(listOf(0), text = "Save", clickable = true).copy(
                semanticEligible = true, observedChildCount = 0,
            )),
            PhoneControlObserveRequest(), false, false, true,
        ).records.getValue("n0")
        assertNull(PhoneControlSemanticIdentity.clickEvidenceDenial(
            record.semanticFlagsUnavailable, record.semanticIdentity != null,
            record.semanticOwnIncomplete, record.semanticChildrenIncomplete,
        ))
        assertNull(PhoneControlSemanticIdentity.validate(
            record.semanticIdentity, true, false, false, false, false,
            text = { "Save" }, description = { null },
        ))
        assertNull(PhoneControlSemanticIdentity.clickEvidenceDenial(
            false, true, false, false,
        ))
        assertEquals(PhoneControlDenial.NODE_UNAVAILABLE, PhoneControlSemanticIdentity.clickEvidenceDenial(
            false, true, false, true,
        ))
        assertEquals(PhoneControlDenial.NODE_UNAVAILABLE, PhoneControlSemanticIdentity.clickEvidenceDenial(
            false, true, true, false,
        ))
        assertEquals(PhoneControlDenial.NODE_UNAVAILABLE, PhoneControlSemanticIdentity.clickEvidenceDenial(
            true, false, false, false,
        ))
    }

    @Test
    fun completeParentWithTruncatedChildLabelCannotDispatch() {
        val result = PhoneControlTreeShaper.shape(
            listOf(
                testRawNode(listOf(0), text = "Open", clickable = true).copy(semanticEligible = true),
                testRawNode(listOf(0, 0), text = "11 November").copy(semanticEligible = true),
            ), PhoneControlObserveRequest(textBudgetChars = 4), false, false, false,
        )
        val parent = result.records.getValue("n0")
        assertTrue(!parent.semanticOwnIncomplete)
        assertTrue(parent.semanticChildrenTextIncomplete)
        assertEquals(PhoneControlDenial.NODE_UNAVAILABLE, PhoneControlSemanticIdentity.clickEvidenceDenial(
            parent.semanticFlagsUnavailable, parent.semanticIdentity != null,
            parent.semanticOwnIncomplete, parent.semanticChildrenIncomplete,
            childrenTextIncomplete = parent.semanticChildrenTextIncomplete,
        ))
        assertEquals(PhoneControlDenial.NODE_UNAVAILABLE, PhoneControlSemanticIdentity.clickEvidenceDenial(
            false, true, false, true,
        ))
    }

    @Test
    fun missingSelectedOrUnscannedTargetChildIsUnavailableButOtherOmissionIsNot() {
        fun parent(result: PhoneControlShaped) = result.records.getValue("n0")
        val target = testRawNode(listOf(0), text = "Date", clickable = true)
            .copy(semanticEligible = true, observedChildCount = 1)
        val child = testRawNode(listOf(0, 0), text = "11")
            .copy(semanticEligible = true, observedChildCount = 0)
        val excluded = parent(PhoneControlTreeShaper.shape(
            listOf(target, child), PhoneControlObserveRequest(maxNodes = 1), false, false, false,
        ))
        assertTrue(excluded.semanticChildrenIncomplete)
        assertEquals(PhoneControlDenial.NODE_UNAVAILABLE, PhoneControlSemanticIdentity.clickEvidenceDenial(
            false, true, false, excluded.semanticChildrenIncomplete,
        ))
        val missingScan = parent(PhoneControlTreeShaper.shape(
            listOf(target), PhoneControlObserveRequest(), false, false, true,
        ))
        assertTrue(missingScan.semanticChildrenIncomplete)
        val completeTarget = target.copy(observedChildCount = 0)
        val other = testRawNode(listOf(1), text = "other").copy(semanticEligible = true, observedChildCount = 0)
        val unrelatedOmission = parent(PhoneControlTreeShaper.shape(
            listOf(completeTarget, other), PhoneControlObserveRequest(maxNodes = 1), false, false, true,
        ))
        assertTrue(!unrelatedOmission.semanticChildrenIncomplete)
        assertNull(PhoneControlSemanticIdentity.clickEvidenceDenial(
            false, true, false, unrelatedOmission.semanticChildrenIncomplete,
        ))
    }

}
