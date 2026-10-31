// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneControlRedactionTest {
    private val request = PhoneControlObserveRequest(
        maxNodes = 64,
        maxDepth = 8,
        includeInvisible = false,
        textBudgetChars = 1_000,
    )

    @Test
    fun passwordFieldsNeverExposeTextDescriptionOrHint() {
        val shaped = PhoneControlTreeShaper.shape(
            raw = listOf(
                testRawNode(path = emptyList(), className = "android.widget.EditText"),
                testRawNode(
                    path = listOf(0),
                    viewId = "com.example.app:id/password",
                    text = "correct horse battery staple",
                    contentDescription = "PIN 1234",
                    hintText = "Enter password",
                    password = true,
                    editable = true,
                ),
            ),
            request = request,
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        val field = shaped.nodes[1]
        assertNull(field.text)
        assertNull(field.contentDescription)
        assertNull(field.hintText)
        assertTrue(field.password)
        assertTrue(field.redacted)
        assertTrue(shaped.sensitiveWindow)
    }

    @Test
    fun sensitiveViewIdsAreRedactedButSpinnerAndShippingAreNot() {
        assertTrue(PhoneControlText.isSensitiveViewId("com.example.app:id/password"))
        assertTrue(PhoneControlText.isSensitiveViewId("editTextPin"))
        assertTrue(PhoneControlText.isSensitiveViewId("com.example.app:id/pin_entry"))
        assertTrue(PhoneControlText.isSensitiveViewId("otpCode"))
        assertFalse(PhoneControlText.isSensitiveViewId("spinner"))
        assertFalse(PhoneControlText.isSensitiveViewId("com.example.app:id/shippingAddress"))
        assertFalse(PhoneControlText.isSensitiveViewId("spin_button"))
        assertFalse(PhoneControlText.isSensitiveViewId(null))
    }

    @Test
    fun sensitiveViewIdIsRedactedEvenWhenTheFrameworkPasswordFlagIsFalse() {
        val shaped = PhoneControlTreeShaper.shape(
            raw = listOf(
                testRawNode(path = emptyList()),
                testRawNode(
                    path = listOf(0),
                    viewId = "com.example.app:id/verification_code",
                    text = "123456",
                ),
            ),
            request = request,
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        val field = shaped.nodes[1]
        assertNull(field.text)
        assertTrue(field.redacted)
        assertEquals(false, field.password)
        assertTrue(shaped.sensitiveWindow)
    }

    @Test
    fun invisibleAncestorIsDroppedAndVisibleChildReparentsToNearestIncludedNode() {
        val shaped = PhoneControlTreeShaper.shape(
            raw = listOf(
                testRawNode(path = emptyList(), className = "android.widget.FrameLayout"),
                testRawNode(path = listOf(0), visible = false, className = "android.view.ViewGroup"),
                testRawNode(path = listOf(0, 0), text = "Visible child"),
            ),
            request = request,
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        assertEquals(2, shaped.nodes.size)
        assertEquals("n0", shaped.nodes[1].parentRef)
        assertEquals("Visible child", shaped.nodes[1].text)
        // The retained locator still points at the real path, not the shaped index.
        assertEquals(listOf(0, 0), shaped.records["n1"]!!.path)
    }

    @Test
    fun nodeAndDepthCapsAreReportedHonestly() {
        val nodes = listOf(
            testRawNode(path = emptyList()),
            testRawNode(path = listOf(0)),
            testRawNode(path = listOf(1)),
        )
        val shaped = PhoneControlTreeShaper.shape(
            raw = nodes,
            request = request.copy(maxNodes = 2),
            redactAllText = false,
            depthLimited = false,
            nodeLimited = true,
        )
        assertEquals(2, shaped.nodes.size)
        assertTrue(shaped.truncated)
        assertFalse(shaped.maxDepthReached)

        val deep = PhoneControlTreeShaper.shape(
            raw = listOf(
                testRawNode(path = emptyList()),
                testRawNode(path = listOf(0)),
                testRawNode(path = listOf(0, 0)),
            ),
            request = request.copy(maxDepth = 1),
            redactAllText = false,
            depthLimited = true,
            nodeLimited = false,
        )
        assertEquals(2, deep.nodes.size)
        assertTrue(deep.maxDepthReached)
        assertTrue(deep.truncated)
    }

    @Test
    fun textBudgetTruncatesAndMarksTheNode() {
        val shaped = PhoneControlTreeShaper.shape(
            raw = listOf(testRawNode(path = emptyList(), text = "abcdefghij")),
            request = request.copy(textBudgetChars = 5),
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        val node = shaped.nodes.single()
        assertEquals("abcde", node.text)
        assertTrue(node.truncated)
        assertEquals(5, shaped.textChars)
        assertTrue(shaped.truncated)
    }

    @Test
    fun hugeTextIsBoundedBeforeItReachesTheStructuredTree() {
        val shaped = PhoneControlTreeShaper.shape(
            raw = listOf(testRawNode(path = emptyList(), text = "a".repeat(20_000))),
            request = request.copy(textBudgetChars = 10),
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        assertEquals(10, shaped.nodes.single().text!!.length)
        assertTrue(shaped.nodes.single().truncated)
        assertEquals(10, shaped.textChars)
    }

    @Test
    fun passwordTextCannotInfluenceTheScreenFingerprint() {
        fun shapeWithSecret(secret: String): PhoneControlShaped = PhoneControlTreeShaper.shape(
            raw = listOf(
                testRawNode(path = emptyList(), className = "android.widget.FrameLayout"),
                testRawNode(
                    path = listOf(0),
                    password = true,
                    text = secret,
                    viewId = "com.example.app:id/password",
                ),
            ),
            request = request,
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        val first = shapeWithSecret("1234")
        val second = shapeWithSecret("987654")
        assertEquals(first.fingerprint, second.fingerprint)
        assertNull(first.nodes[1].text)
    }

    @Test
    fun protectedWindowRedactsAllText() {
        val shaped = PhoneControlTreeShaper.shape(
            raw = listOf(
                testRawNode(path = emptyList(), text = "Notification body"),
                testRawNode(path = listOf(0), text = "Sender"),
            ),
            request = request,
            redactAllText = true,
            depthLimited = false,
            nodeLimited = false,
        )
        assertTrue(shaped.sensitiveWindow)
        assertTrue(shaped.nodes.all { it.redacted })
        assertTrue(shaped.nodes.all { it.text == null })
    }

    @Test
    fun boundsFlagsAndParentRefsArePreserved() {
        val shaped = PhoneControlTreeShaper.shape(
            raw = listOf(
                testRawNode(path = emptyList(), className = "android.widget.FrameLayout"),
                testRawNode(
                    path = listOf(0),
                    bounds = PhoneControlBounds(10, 20, 110, 220),
                    clickable = true,
                    scrollable = true,
                ),
            ),
            request = request,
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        val child = shaped.nodes[1]
        assertEquals("n0", child.parentRef)
        assertEquals(1, child.depth)
        assertEquals(PhoneControlBounds(10, 20, 110, 220), child.bounds)
        assertTrue(child.clickable)
        assertTrue(child.scrollable)
        assertEquals(listOf(0), shaped.records[child.ref]!!.path)
    }
}
