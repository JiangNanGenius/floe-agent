// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The explicit Ask AI draft is the USER-VISIBLE composer text. It names the
 * project and keeps the user's instruction; the exact project identity is
 * delivered to the model through the trusted native task context, never as a
 * raw UUID/revision in the composer or chat body.
 */
class MediaAgentDraftTextTest {

    private val uuidPattern = Regex(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-" +
            "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    )

    @Test
    fun englishDraftNamesTheProjectAndKeepsTheInstruction() {
        val text = mediaAgentDraftText(
            projectName = "  Launch still  ",
            instruction = "  Warm up the sky  ",
            zh = false,
        )
        assertEquals(
            "Please edit the media project \u201cLaunch still\u201d.\nWarm up the sky",
            text,
        )
        assertTrue(text.contains("Launch still"))
        assertFalse("no raw id", uuidPattern.containsMatchIn(text))
        assertFalse("no internal tool name", text.contains("media.project"))
        assertFalse("no raw revision", text.contains("revision"))
    }

    @Test
    fun chineseDraftNamesTheProjectAndKeepsTheInstruction() {
        val text = mediaAgentDraftText(
            projectName = "海报初稿",
            instruction = "把天空调暖一点",
            zh = true,
        )
        assertEquals(
            "请编辑媒体项目「海报初稿」。\n把天空调暖一点",
            text,
        )
        assertFalse(uuidPattern.containsMatchIn(text))
        assertFalse(text.contains("media.project"))
    }

    @Test
    fun blankProjectNameFallsBackToAReadableLabel() {
        val english = mediaAgentDraftText(
            projectName = "   ",
            instruction = "",
            zh = false,
        )
        assertEquals("Please edit the media project \u201cthe open media project\u201d.", english)
        val chinese = mediaAgentDraftText(
            projectName = "",
            instruction = "",
            zh = true,
        )
        assertEquals("请编辑媒体项目「当前媒体项目」。", chinese)
    }

    @Test
    fun overlongProjectNameIsBounded() {
        val text = mediaAgentDraftText(
            projectName = "x".repeat(400),
            instruction = "",
            zh = false,
        )
        assertTrue(text.length < 200)
        assertFalse(uuidPattern.containsMatchIn(text))
    }
}
