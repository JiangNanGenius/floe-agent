// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Conversation media refresh wire + workspace-open policy regressions
 * (job-264a807c8a364c8a, source-only lane; Main executes the suite).
 *
 * The v28 envelope is the ONLY refresh surface: it must build the exact
 * closed `media.jobs.refresh` command, never carry credentials, and parse
 * replies without fabricating success. The open policy must refuse the
 * lexical escapes a model-provided path could try before the native guard
 * ever runs.
 */
class ConversationMediaWireTest {

    @Test
    fun `refresh request carries exact closed envelope`() {
        val request = ConversationMediaWire.refreshRequest(
            requestID = "req-1",
            epoch = 42L,
            conversationID = "3f6f8f9c-7d4a-4c1e-9b2a-1c5e8d3f6a70",
        )
        assertTrue(request.contains("\"version\":28"))
        assertTrue(request.contains("\"operation\":\"command\""))
        assertTrue(request.contains("\"epoch\":42"))
        assertTrue(request.contains("\"action\":\"media.jobs.refresh\""))
        assertTrue(request.contains("\"conversationID\":\"3f6f8f9c-7d4a-4c1e-9b2a-1c5e8d3f6a70\""))
        assertTrue(request.contains("\"requestID\":\"req-1\""))
        // No credential/secrets surface exists on this wire at all.
        assertFalse(request.contains("apiKey"))
        assertFalse(request.contains("Authorization"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `refresh request refuses non-positive epoch`() {
        ConversationMediaWire.refreshRequest("req", 0L, "3f6f8f9c-7d4a-4c1e-9b2a-1c5e8d3f6a70")
    }

    @Test
    fun `parse success returns bounded durable projections`() {
        val jobs = (1..60).joinToString(",") { index ->
            """{"jobID":"00000000-0000-0000-0000-%012d",
               "state":"running","terminated":false,"ready":false,
               "mediaKind":"video"}""".trimIndent().replace("\n", "").format(index)
        }
        val result = ConversationMediaWire.parseRefreshResponse(
            """{"ok":true,"schema":"floe.agentmedia/28","jobs":[$jobs],"count":60}""".trimIndent())
        assertNull(result.error)
        assertEquals(ConversationMediaWire.MAX_JOBS, result.jobs.size)
        assertEquals("video", result.jobs.first().mediaKind)
        assertEquals("running", result.jobs.first().state)
    }

    @Test
    fun `parse ready job exposes typed artifact receipt`() {
        val result = ConversationMediaWire.parseRefreshResponse(
            """
            {"ok":true,"jobs":[{"jobID":"a3ee7f2c-0000-4000-8000-9f6e5d4c3b2a",
              "state":"ready","terminated":true,"ready":true,"mediaKind":"video",
              "workspaceRelativePath":"GeneratedMedia/video-a3ee7f2c.mp4",
              "deliveredByteCount":1234567,
              "deliveredSHA256":"ab12cd34","lastError":null}]}
            """.trimIndent())
        assertNull(result.error)
        val job = result.jobs.single()
        assertTrue(job.ready)
        assertTrue(job.terminated)
        assertEquals("GeneratedMedia/video-a3ee7f2c.mp4", job.workspaceRelativePath)
        assertEquals(1234567L, job.deliveredByteCount)
        assertEquals("ab12cd34", job.deliveredSHA256)
    }

    @Test
    fun `parse typed failure carries the native code`() {
        val result = ConversationMediaWire.parseRefreshResponse(
            """{"ok":false,"error":"staleGeneration","retryable":true}""")
        assertEquals("staleGeneration", result.error)
        assertTrue(result.jobs.isEmpty())
    }

    @Test
    fun `parse failure bounds hostile or oversized codes`() {
        val hostile = ConversationMediaWire.parseRefreshResponse(
            """{"ok":false,"error":"bad code with spaces<script>"}""")
        assertEquals("mediaRefreshFailed", hostile.error)
        val huge = ConversationMediaWire.parseRefreshResponse(
            """{"ok":false,"error":"${"a".repeat(200)}"}""")
        assertEquals("mediaRefreshFailed", huge.error)
    }

    @Test
    fun `parse malformed reply is a typed error never a fabricated success`() {
        assertEquals("invalidResponse",
            ConversationMediaWire.parseRefreshResponse("not json").error)
        assertEquals("invalidResponse",
            ConversationMediaWire.parseRefreshResponse("{\"ok\":true,\"jobs\":\"nope\"}").error)
        // A structurally valid but job-less reply stays honest: no jobs, no
        // error — never an invented projection.
        val empty = ConversationMediaWire.parseRefreshResponse(
            "{\"ok\":true,\"jobs\":[{}]}")
        assertNull(empty.error)
        assertTrue(empty.jobs.isEmpty())
    }

    @Test
    fun `open policy admits ordinary relative paths`() {
        assertTrue(WorkspaceOpenPolicy.relativePathAdmitted("GeneratedMedia/video-a.mp4"))
        assertTrue(WorkspaceOpenPolicy.relativePathAdmitted("notes/report.md"))
        assertTrue(WorkspaceOpenPolicy.relativePathAdmitted("a/b/c.PNG"))
        assertTrue(WorkspaceOpenPolicy.relativePathAdmitted("file.txt"))
    }

    @Test
    fun `open policy refuses traversal and absolute roots`() {
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted("../escape.txt"))
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted("a/../../escape.txt"))
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted("/etc/passwd"))
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted("\\server\\share"))
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted("~/secret"))
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted(""))
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted("   "))
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted("a".repeat(600)))
        assertFalse(WorkspaceOpenPolicy.relativePathAdmitted("a\u0000b.txt"))
    }
}
