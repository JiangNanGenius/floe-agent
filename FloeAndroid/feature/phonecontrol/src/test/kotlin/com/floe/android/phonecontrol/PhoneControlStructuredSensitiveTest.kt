// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The ADB structured adapter must keep the existing protected-field contract:
 * the page is flagged sensitive, the password value is never present, the
 * screenshot surface stays refused, and the model-facing ref still resolves
 * to the real service ref so an explicit authorized sensitive fill can target
 * that exact node.
 */
class PhoneControlStructuredSensitiveTest {

    private val owner = PhoneControlOwner(UUID.randomUUID(), UUID.randomUUID())
    private val canary = "CANARY-password-value"

    private fun node(
        ref: String,
        path: List<Int>,
        text: String?,
        password: Boolean = false,
        editable: Boolean = false,
        actions: Set<String> = emptySet(),
    ) = PhoneControlStructuredNode(
        ref = ref,
        parentRef = if (path.isEmpty()) null else path.dropLast(1).toString(),
        path = path,
        depth = path.size,
        className = "android.widget.EditText",
        packageName = "com.example.target",
        viewId = if (password) "com.example.target:id/password" else "com.example.target:id/user",
        text = text,
        contentDescription = null,
        hintText = null,
        bounds = PhoneControlBounds(0, 0, 320, 48),
        visible = true,
        enabled = true,
        clickable = false,
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
        windowId = 9,
        windowType = 1,
        windowTitle = "Login",
        displayId = 0,
        rootClassName = "android.widget.LinearLayout",
        rotation = 0,
        capturedAtElapsedRealtimeMillis = 1_000L,
        expiresAtElapsedRealtimeMillis = 121_000L,
        generation = 4L,
        userInteractionRevision = 1L,
        nodes = nodes,
        scannedNodeCount = nodes.size,
        truncated = false,
        maxDepthReached = false,
        scanLimited = false,
        timeLimited = false,
        textLimited = false,
        sensitiveWindow = false,
        hasSensitiveField = true,
        navigationOnly = false,
    )

    @Test fun protectedPageStaysSensitiveWithoutReadingThePasswordValue() {
        val mapped = PhoneControlStructuredAdapter.toMapped(
            page(listOf(
                node("svc-user", emptyList(), text = "alice", editable = true,
                    actions = setOf("setText")),
                node("svc-pass", listOf(1), text = canary, password = true,
                    editable = true, actions = setOf("setText")),
            )),
            owner,
            fenceGeneration = 2L,
        )
        val observation = mapped.observation
        assertTrue(observation.sensitiveWindow)
        val secret = observation.nodes.first { it.password }
        assertNull(secret.text)
        assertFalse(observation.nodes.any { it.text?.contains(canary) == true })
        assertEquals("svc-pass", mapped.refAliases[secret.ref])
    }

    @Test fun ordinaryAndProtectedFieldsKeepDistinctAliases() {
        val mapped = PhoneControlStructuredAdapter.toMapped(
            page(listOf(
                node("svc-user", emptyList(), text = "alice", editable = true),
                node("svc-pass", listOf(1), text = canary, password = true, editable = true),
            )),
            owner,
            fenceGeneration = 3L,
        )
        val user = mapped.observation.nodes.first { it.editable && !it.password }
        val secret = mapped.observation.nodes.first { it.password }
        assertEquals("svc-user", mapped.refAliases[user.ref])
        assertEquals("svc-pass", mapped.refAliases[secret.ref])
    }
}
