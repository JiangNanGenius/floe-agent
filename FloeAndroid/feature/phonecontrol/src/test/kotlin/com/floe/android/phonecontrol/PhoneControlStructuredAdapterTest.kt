// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class PhoneControlStructuredAdapterTest {

    private val owner = PhoneControlOwner(UUID.randomUUID(), UUID.randomUUID())

    private fun node(
        ref: String,
        path: List<Int>,
        text: String? = null,
        password: Boolean = false,
        editable: Boolean = false,
        clickable: Boolean = false,
        actions: Set<String> = emptySet(),
        visible: Boolean = true,
        bounds: PhoneControlBounds = PhoneControlBounds(0, 0, 100, 40),
    ) = PhoneControlStructuredNode(
        ref = ref,
        parentRef = if (path.isEmpty()) null else path.dropLast(1).toString(),
        path = path,
        depth = path.size,
        className = if (editable) "android.widget.EditText" else "android.widget.TextView",
        packageName = "com.example.target",
        viewId = null,
        text = text,
        contentDescription = null,
        hintText = null,
        bounds = bounds,
        visible = visible,
        enabled = true,
        clickable = clickable,
        editable = editable,
        scrollable = false,
        focusable = editable,
        focused = false,
        selected = false,
        checkable = false,
        checked = false,
        password = password,
        redacted = password,
        insideScrollable = false,
        actions = actions,
        range = null,
    )

    private fun page(nodes: List<PhoneControlStructuredNode>) = PhoneControlStructuredPage(
        observationId = "server-id",
        packageName = "com.example.target",
        windowId = 7,
        windowType = 1,
        windowTitle = "Target",
        displayId = 0,
        rootClassName = "android.widget.FrameLayout",
        rotation = 0,
        capturedAtElapsedRealtimeMillis = 1_000L,
        expiresAtElapsedRealtimeMillis = 121_000L,
        generation = 3L,
        userInteractionRevision = 2L,
        nodes = nodes,
        scannedNodeCount = nodes.size,
        truncated = false,
        maxDepthReached = false,
        scanLimited = false,
        timeLimited = false,
        textLimited = false,
        sensitiveWindow = false,
        navigationOnly = false,
    )

    @Test fun adbPageKeepsRealBackendAndPrefixedObservationId() {
        val observation = PhoneControlStructuredAdapter.toObservation(
            page(listOf(node("n0", emptyList()))), owner, fenceGeneration = 5L)
        assertEquals("adbui-server-id", observation.observationId)
        assertEquals(PhoneControlBackend.ADB_UI_AUTOMATION, observation.backend)
        assertEquals("adbUiAutomation", observation.provenance)
        assertEquals(7, observation.windowId)
        assertEquals(5L, observation.fenceGeneration)
    }

    @Test fun passwordTextIsNeverPresentAndRealActionsSurvive() {
        val observation = PhoneControlStructuredAdapter.toObservation(
            page(listOf(
                node("n0", emptyList(), text = "Account"),
                node("n1", listOf(0), text = "secret-value", password = true),
                node("n2", listOf(2), text = "Save", clickable = true,
                    actions = setOf("click", "longClick")),
            )),
            owner,
            fenceGeneration = 1L,
        )
        val secret = observation.nodes.firstOrNull { it.ref == "n1" }
        assertTrue(secret?.password == true)
        assertTrue(secret?.text == null)
        val save = observation.nodes.first { it.ref == "n2" }
        assertTrue(save.clickable)
        assertTrue(save.advertises(PhoneControlNodeAction.CLICK))
        assertTrue(save.advertises(PhoneControlNodeAction.LONG_CLICK))
    }

    @Test fun navigationOnlyPageCarriesNoNodeContentOrScreenshotClaim() {
        val observation = PhoneControlStructuredAdapter.toObservation(
            page(emptyList()).copy(packageName = "com.example.launcher", navigationOnly = true),
            owner,
            fenceGeneration = 1L,
        )
        assertTrue(observation.navigationOnly)
        assertTrue(observation.nodes.isEmpty())
        assertTrue(observation.sensitiveWindow)
        assertEquals(PhoneControlScreenshotSupport.DISPLAY, observation.screenshotSupport)
    }

    @Test fun appNodeRefsKeepAnAliasToTheServiceRefForDispatch() {
        val mapped = PhoneControlStructuredAdapter.toMapped(
            page(listOf(
                node("svc-root", emptyList(), text = "Root"),
                node("svc-save", listOf(1), text = "Save", clickable = true),
            )),
            owner,
            fenceGeneration = 1L,
        )
        val save = mapped.observation.nodes.first { it.text == "Save" }
        assertEquals("svc-save", mapped.refAliases[save.ref])
    }

    @Test fun visibilityAndDepthBoundsAreRetainedAsRealTruncationFacts() {
        val observation = PhoneControlStructuredAdapter.toObservation(
            page(listOf(node("n0", emptyList(), visible = false))).copy(
                truncated = true,
                maxDepthReached = true,
            ),
            owner,
            fenceGeneration = 1L,
            request = PhoneControlObserveRequest(maxNodes = 250, maxDepth = 32),
        )
        assertTrue(observation.truncated)
        assertTrue(observation.maxDepthReached)
        assertTrue(observation.nodes.isEmpty())
    }
}
