// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingexchange

import com.floe.android.host.meeting.MeetingDetail
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Layout of the lightweight PDF document export. The pure layout decides every
 * line that the platform renderer draws, so verifying it line by line is the
 * readability contract for the PDF: the exact transcript, notes and metadata
 * text reaches the page, wrapped and paginated, with nothing truncated.
 */
class MeetingPdfLayoutTest {

    @Test
    fun `layout starts with title metadata notes then transcript`() {
        val layout = build(
            MeetingExportTestFixtures.detail(
                title = "Weekly review",
                notes = "A note",
                materials = listOf(MeetingExportTestFixtures.material("material-1")),
                segments = listOf(
                    MeetingExportTestFixtures.segment(65_000L, 70_000L, "Spoken text", "Alex"),
                ),
            ),
        )
        val all = layout.pages.flatMap { it.lines }.map { it.text }

        assertEquals("Weekly review", all.first())
        assertTrue(all.any { it.startsWith("Created: ") })
        assertTrue(all.any { it.startsWith("Updated: ") })
        assertTrue(all.any { it.contains("Materials: 1") })
        assertTrue(all.any { it == "Notes" })
        assertTrue(all.contains("A note"))
        assertTrue(all.any { it == "Transcript" })
        assertTrue(all.contains("[00:01:05 – 00:01:10] Alex: Spoken text"))
    }

    @Test
    fun `title is larger and bold body is neither`() {
        val layout = build(MeetingExportTestFixtures.detail(title = "T"))
        val title = layout.pages.first().lines.first()
        assertTrue(title.bold)
        assertEquals(MeetingPdfLayoutBuilder.TITLE_SIZE, title.textSize)
        val body = layout.pages.first().lines[1]
        assertFalse(body.bold)
        assertEquals(MeetingPdfLayoutBuilder.BODY_SIZE, body.textSize)
    }

    @Test
    fun `long transcript lines wrap without losing content`() {
        val longText = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon"
        val layout = build(
            MeetingExportTestFixtures.detail(
                notes = "",
                segments = listOf(MeetingExportTestFixtures.segment(0L, 1_000L, longText)),
            ),
        )
        val all = layout.pages.flatMap { it.lines }.map { it.text }
        val transcriptLines = afterHeading(all, MeetingExportTestFixtures.LABELS.transcriptHeading)
            .filter { it.isNotEmpty() }
        assertTrue("expected the long line to wrap, got $transcriptLines", transcriptLines.size > 1)
        assertTrue(
            transcriptLines.all {
                MeetingPdfLayoutBuilder.wrap(it, MeetingPdfLayoutBuilder.BODY_SIZE, usableWidth()).size == 1
            },
        )
        // Every token survives the wrap.
        transcriptLines.joinToString(" ").let { joined ->
            listOf("alpha", "beta", "gamma", "delta", "upsilon").forEach { token ->
                assertTrue(token, joined.contains(token))
            }
        }
    }

    @Test
    fun `content taller than one page paginates`() {
        val segments = (1..200).map {
            MeetingExportTestFixtures.segment(
                it * 1_000L,
                it * 1_000L + 500L,
                "Segment number $it with enough words to keep the page busy for a while",
            )
        }
        val layout = build(MeetingExportTestFixtures.detail(notes = "", segments = segments))
        assertTrue("expected multiple pages, got ${layout.pages.size}", layout.pages.size > 1)
        // The first and the last segment still appear across the pages, even
        // though each long segment line wraps across two drawn lines.
        val all = layout.pages.flatMap { it.lines }.map { it.text }
        assertTrue(all.any { it.contains("Segment number 1 ") || it.endsWith("Segment number 1") })
        assertTrue(all.any { it.contains("Segment number 200") })
    }

    @Test
    fun `empty notes and transcript stay explicit statements`() {
        val layout = build(MeetingExportTestFixtures.detail(notes = "", segments = emptyList()))
        val all = layout.pages.flatMap { it.lines }.map { it.text }
        assertTrue(all.contains(MeetingExportTestFixtures.LABELS.noNotes))
        assertTrue(all.contains(MeetingExportTestFixtures.LABELS.noTranscript))
    }

    @Test
    fun `cjk text wraps by character and survives`() {
        val layout = build(
            MeetingExportTestFixtures.detail(
                notes = "",
                segments = listOf(
                    MeetingExportTestFixtures.segment(
                        0L,
                        1_000L,
                        "这是一个足够长的中文句子用来验证自动换行的行为表现是否符合预期",
                        "张三",
                    ),
                ),
            ),
        )
        val all = layout.pages.flatMap { it.lines }.map { it.text }
        assertTrue(all.any { it.startsWith("[00:00:00") })
        assertTrue("CJK content must survive the layout", all.any { it.contains("这是一个") })
        // No line exceeds the usable width at body size.
        all.forEach { line ->
            assertTrue(
                "line too wide: $line",
                MeetingPdfLayoutBuilder.wrap(line, MeetingPdfLayoutBuilder.BODY_SIZE, usableWidth()).size == 1,
            )
        }
    }

    @Test
    fun `wrap returns the paragraph unchanged when it fits`() {
        assertEquals(listOf("short line"), MeetingPdfLayoutBuilder.wrap("short line", 11f, usableWidth()))
        assertEquals(listOf(""), MeetingPdfLayoutBuilder.wrap("", 11f, usableWidth()))
    }

    private fun build(detail: MeetingDetail) =
        MeetingPdfLayoutBuilder.build(
            MeetingExportSnapshot.from(detail),
            MeetingExportTestFixtures.LABELS,
            MeetingExportTestFixtures.UTC,
        )

    /** Lines that follow the first [heading] line, across all pages. */
    private fun afterHeading(lines: List<String>, heading: String): List<String> {
        val index = lines.indexOf(heading)
        if (index < 0) return emptyList()
        return lines.subList(index + 1, lines.size)
    }

    private fun usableWidth() =
        (MeetingPdfLayoutBuilder.PAGE_WIDTH - 2 * MeetingPdfLayoutBuilder.MARGIN_X).toFloat()
}
