// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.RunEventKindUi
import com.floe.android.feature.conversation.RunEventUi
import com.floe.android.feature.conversation.RunFileChangeUi
import com.floe.android.feature.conversation.ThreadUiState
import com.floe.android.feature.conversation.TimelineRowUi
import com.floe.android.feature.conversation.ToolEventProjectionUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Per-run file-change receipts (⇄ iOS RunFileChangeList, Android producer
 * vocabulary) and their projection: only genuine ok/effect receipts become
 * rows; retried calls keep earlier receipts; the row survives cold reload
 * and rides beside the same run's sealed output cards. */
class RunFileChangeReceiptsTest {

    private val run = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private fun result(
        call: String,
        tool: String,
        summary: String,
        status: String = "ok",
        outcomeUnknown: Boolean = false,
    ) = RunEventUi(
        id = "$run:1", runId = run, sequence = 1, kind = RunEventKindUi.TOOL_RESULT,
        timeLabel = "",
        tool = ToolEventProjectionUi(
            callId = call, toolName = tool, statusRaw = status, resultSummary = summary,
            outcomeUnknown = outcomeUnknown,
        ),
    )

    private fun request(call: String, tool: String, input: String) = RunEventUi(
        id = "$run:0", runId = run, sequence = 0, kind = RunEventKindUi.TOOL_REQUEST,
        timeLabel = "",
        tool = ToolEventProjectionUi(
            callId = call, toolName = tool, statusRaw = "pending", inputSummary = input,
        ),
    )

    /* ------------------------------ genuine receipts ------------------------------ */

    @Test
    fun writeReceiptsProduceActualPathsAndActions() {
        val changes = RunFileChangeReceipts.changesFor(listOf(
            request("c1", "workspace.createFile", """{"path":"notes/new.txt"}"""),
            result("c1", "workspace.createFile",
                "created=notes/new.txt bytes=3 sha256=deadbeef mtime=1 saved=true preview=available"),
            result("c2", "workspace.writeFile",
                "written=notes/existing.txt bytes=12 sha256=cafe mtime=2 saved=true preview=available"),
            result("c3", "workspace.applyPatch",
                "patched=src/app.kt hunks=2 added=4 removed=1 sha256=beef"),
            result("c4", "workspace.deleteFile",
                "deleted=old.txt recursive=false"),
            result("c5", "workspace.copyFile",
                "copied=tpl/a.txt -> out/a.txt"),
            request("c6", "workspace.createFile", """{"path":"notes/replaced.txt","overwrite":true}"""),
            result("c6", "workspace.createFile", "created=notes/replaced.txt bytes=3 sha256=a mtime=1"),
            result("c7", "workspace.appendFile", "edited=notes/append.txt bytes=3 sha256=b mtime=1"),
        ))
        assertEquals(listOf(
            "notes/new.txt" to RunFileChangeUi.ACTION_ADDED,
            "notes/existing.txt" to RunFileChangeUi.ACTION_EDITED,
            "src/app.kt" to RunFileChangeUi.ACTION_EDITED,
            "old.txt" to RunFileChangeUi.ACTION_DELETED,
            "out/a.txt" to RunFileChangeUi.ACTION_ADDED,
            "notes/replaced.txt" to RunFileChangeUi.ACTION_SAVED,
            "notes/append.txt" to RunFileChangeUi.ACTION_EDITED,
        ), changes.map { it.path to it.actionRaw })
        // Stable per-run keys and honest producer labels.
        assertTrue(changes.all { it.id == "path:${it.path}" })
        assertEquals("workspace.applyPatch", changes[2].toolName)
    }

    @Test
    fun networkReceiptVariantsParseTheSameDisplayPaths() {
        val changes = RunFileChangeReceipts.changesFor(listOf(
            request("c1", "workspace.createFile", """{"path":"remote/note.txt","overwrite":false}"""),
            result("c1", "workspace.createFile",
                "created=remote/note.txt bytes=3 sha256=deadbeef mtime=1 network=true"),
            result("c2", "workspace.moveFile",
                "moved=dir/a.txt -> dir/b.txt network=true"),
        ))
        assertEquals(listOf(
            "remote/note.txt" to RunFileChangeUi.ACTION_ADDED,
            "dir/b.txt" to RunFileChangeUi.ACTION_MOVED,
        ), changes.map { it.path to it.actionRaw })
    }

    @Test
    fun moveFoldsOriginIntoDestinationAndKeepsAdded() {
        val changes = RunFileChangeReceipts.changesFor(listOf(
            request("c1", "workspace.createFile", """{"path":"draft.txt"}"""),
            result("c1", "workspace.createFile",
                "created=draft.txt bytes=1 sha256=a mtime=1 saved=true preview=available"),
            result("c2", "workspace.moveFile", "moved=draft.txt -> final.txt"),
        ))
        assertEquals(listOf("final.txt" to RunFileChangeUi.ACTION_ADDED),
            changes.map { it.path to it.actionRaw })
    }

    @Test
    fun deleteOfAnAddedFileCancelsTheEntry() {
        val changes = RunFileChangeReceipts.changesFor(listOf(
            request("c1", "workspace.createFile", """{"path":"tmp.txt"}"""),
            result("c1", "workspace.createFile",
                "created=tmp.txt bytes=1 sha256=a mtime=1 saved=true preview=available"),
            result("c2", "workspace.deleteFile", "deleted=tmp.txt recursive=false"),
        ))
        assertTrue(changes.isEmpty())
    }

    @Test
    fun publishDeliversAnAlreadyChangedFileButNeverMintsAWrite() {
        // ⇄ iOS RunFileChangeList.record: a publish keeps the entry's write
        // action (the delivery attaches sealed-output evidence, shown beside
        // the row as the run's owned output cards) — never a bare "publish".
        val delivered = RunFileChangeReceipts.changesFor(listOf(
            request("c1", "workspace.publishOutput", """{"path":"report.docx"}"""),
            request("c0", "workspace.createFile", """{"path":"report.docx"}"""),
            result("c0", "workspace.createFile",
                "created=report.docx bytes=9 sha256=a mtime=1 saved=true preview=available"),
            // The publish result carries the SAME call id as its request.
            result("c1", "workspace.publishOutput",
                "published=report.docx bytes=9 sha256=a output=RunOutputs/x/report.docx"),
        ))
        assertEquals(listOf("report.docx" to RunFileChangeUi.ACTION_ADDED),
            delivered.map { it.path to it.actionRaw })
        // Publishing a file this run never changed: no workspace write row.
        val bare = RunFileChangeReceipts.changesFor(listOf(
            request("c9", "workspace.publishOutput", """{"path":"report.docx"}"""),
            result("c9", "workspace.publishOutput",
                "published=report.docx bytes=9 sha256=a output=RunOutputs/x/report.docx"),
        ))
        assertTrue(bare.isEmpty())
    }

    /* --------------------------- rejected / no-op receipts --------------------------- */

    @Test
    fun failedInterruptedUnknownAndNoopReceiptsNeverCount() {
        val changes = RunFileChangeReceipts.changesFor(listOf(
            // Interrupted / failed results: no verified effect.
            result("c1", "workspace.createFile", "created=x.txt bytes=1 sha256=a mtime=1",
                status = "failed"),
            result("c2", "workspace.writeFile", "written=y.txt bytes=1 sha256=a mtime=1",
                status = "cancelled"),
            // Explicit no-op marker (shared/legacy receipts).
            result("c3", "workspace.writeFile",
                "written=z.txt bytes=0 sha256=a paths={} change=unchanged saved=true"),
            // Unknown tool echoing a write-looking receipt.
            result("c4", "workspace.createDirectory", "created=dir.txt"),
            // Malformed: missing field delimiter.
            result("c5", "workspace.createFile", "created=broken"),
            // Hostile display paths never render.
            result("c6", "workspace.createFile",
                "created=/etc/passwd bytes=1 sha256=a mtime=1"),
            result("c7", "workspace.createFile",
                "created=../escape.txt bytes=1 sha256=a mtime=1"),
            result("c8", "workspace.writeFile",
                "written=a.txt bytes=1 sha256=a mtime=1 saved=true preview=available"),
            result("c9", "workspace.writeFile", "written=uncertain.txt bytes=1 sha256=a mtime=1",
                outcomeUnknown = true),
        ))
        assertEquals(listOf("a.txt" to RunFileChangeUi.ACTION_EDITED),
            changes.map { it.path to it.actionRaw })
    }

    /* ------------------------------- retry regression ------------------------------- */

    @Test
    fun earlierReceiptSurvivesALaterFailedRetryOfTheSameCall() {
        // ⇄ db3d1b4ee: the request card may now present the late failure,
        // but the genuine earlier export must stay visible on its own result.
        val changes = RunFileChangeReceipts.changesFor(listOf(
            request("call-1", "workspace.createFile", """{"path":"keep.txt"}"""),
            result("call-1", "workspace.createFile",
                "created=keep.txt bytes=1 sha256=a mtime=1 saved=true preview=available"),
            result("call-1", "workspace.createFile", "create failed: quota",
                status = "failed"),
        ))
        assertEquals(listOf("keep.txt" to RunFileChangeUi.ACTION_ADDED),
            changes.map { it.path to it.actionRaw })
    }

    @Test
    fun failedFirstAttemptThenOkRetryRecordsTheChange() {
        val changes = RunFileChangeReceipts.changesFor(listOf(
            result("call-1", "workspace.writeFile", "write failed: locked",
                status = "failed"),
            result("call-1", "workspace.writeFile",
                "written=retry.txt bytes=2 sha256=b mtime=3 saved=true preview=available"),
        ))
        assertEquals(listOf("retry.txt" to RunFileChangeUi.ACTION_EDITED),
            changes.map { it.path to it.actionRaw })
    }

    /* ------------------------------ projection integration ------------------------------ */

    private fun frame(sequence: Long, kind: String, payload: String) = HostRunEventFrame(
        runID = run, sequence = sequence, kind = kind,
        payload = Json.parseToJsonElement(payload).jsonObject, bytes = payload.length,
    )

    private fun groups(state: ThreadUiState) =
        state.rows.filterIsInstance<TimelineRowUi.RunFileChanges>()

    @Test
    fun timelineShowsPerRunFileChangesBesideSealedOutputCards() {
        val conversation = "11111111-2222-3333-4444-555555555555"
        val builder = ThreadProjectionBuilder(conversation)
        builder.applyRunEvent(frame(1, "toolRequest",
            """{"tool":"workspace.createFile","id":"call-1","input":"{\"path\":\"note.txt\"}","status":"pending"}"""))
        builder.applyRunEvent(frame(2, "toolResult",
            """{"tool":"workspace.createFile","id":"call-1","status":"ok","summary":"created=note.txt bytes=3 sha256=a mtime=1 saved=true preview=available"}"""))
        // The sealed generated output of the SAME run stays an owned card.
        builder.applyRunOutputs(run, listOf(
            com.floe.android.feature.conversation.RunOutputCardUi(
                runId = run, outputId = "b".repeat(64), producerCallId = "call-1",
                displayName = "report.docx",
                mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                byteCount = 1024, availabilityRaw = "available",
            )), scanTruncated = false)
        val rows = builder.build().rows
        val changeRow = rows.filterIsInstance<TimelineRowUi.RunFileChanges>()
        assertEquals(1, changeRow.size)
        assertEquals(run, changeRow[0].runId)
        assertEquals("note.txt", changeRow[0].changes[0].path)
        assertEquals(RunFileChangeUi.ACTION_ADDED, changeRow[0].changes[0].actionRaw)
        // Both surfaces coexist for the same run, file changes before cards.
        val outputRow = rows.filterIsInstance<TimelineRowUi.RunOutputGroup>()
        assertEquals(1, outputRow.size)
        assertTrue(rows.indexOf(changeRow[0]) < rows.indexOf(outputRow[0]))
    }

    @Test
    fun coldReloadedRunKeepsChangesFromRecordedEventsWithoutLivePump() {
        val conversation = "11111111-2222-3333-4444-555555555555"
        val builder = ThreadProjectionBuilder(conversation)
        // Cold reopen: the recorded page replays exactly one durable pair.
        builder.applyRecordedEvents(run, listOf(
            frame(1, "toolRequest",
                """{"tool":"workspace.writeFile","id":"call-9","input":"{}","status":"pending"}"""),
            frame(2, "toolResult",
                """{"tool":"workspace.writeFile","id":"call-9","status":"ok","summary":"written=doc.md bytes=7 sha256=c mtime=9 saved=true preview=available"}"""),
        ), hasEarlier = false)
        val changeRow = groups(builder.build())
        assertEquals(1, changeRow.size)
        assertEquals("doc.md", changeRow[0].changes[0].path)
        // Rebuild is stable: the same receipts do not duplicate the row.
        assertEquals(1, groups(builder.build()).size)
    }

    @Test
    fun temporaryChatNeverEmitsFileChangeRows() {
        val conversation = "11111111-2222-3333-4444-555555555555"
        val builder = ThreadProjectionBuilder(conversation)
        builder.isTemporary = true
        builder.applyRecordedEvents(run, listOf(
            frame(1, "toolRequest",
                """{"tool":"workspace.createFile","id":"call-1","input":"{}","status":"pending"}"""),
            frame(2, "toolResult",
                """{"tool":"workspace.createFile","id":"call-1","status":"ok","summary":"created=note.txt bytes=3 sha256=a mtime=1"}"""),
        ), hasEarlier = false)
        assertTrue(groups(builder.build()).isEmpty())
    }

    /* ------------------------- on-demand owned-output refresh ------------------------- */

    @Test
    fun runOutputRefreshIsRequestedOncePerRunPerSession() {
        val conversation = "11111111-2222-3333-4444-555555555555"
        val builder = ThreadProjectionBuilder(conversation)
        // No view yet: the recorded-event lane fills this exact owned run.
        assertTrue(builder.runOutputRefreshNeeded(run))
        // An empty honest answer still counts as requested (removes the group).
        builder.applyRunOutputs(run, emptyList(), scanTruncated = false)
        assertEquals(emptyList<TimelineRowUi.RunOutputGroup>(),
            builder.build().rows.filterIsInstance<TimelineRowUi.RunOutputGroup>())
        // A temporarily unavailable historical read is eligible again later.
        val other = "22222222-3333-4444-5555-666666666666"
        assertTrue(builder.runOutputRefreshNeeded(other))
        builder.markRunOutputRefreshRequested(listOf(other))
        assertTrue(!builder.runOutputRefreshNeeded(other))
        builder.markRunOutputsUnavailable(other)
        assertTrue(builder.runOutputRefreshNeeded(other))
        // Explicit user refresh re-asks and the new verified view replaces.
        builder.applyRunOutputs(run, listOf(
            com.floe.android.feature.conversation.RunOutputCardUi(
                runId = run, outputId = "c".repeat(64), producerCallId = "call-1",
                displayName = "note.txt", mimeType = "text/plain",
                byteCount = 3, availabilityRaw = "available",
            )), scanTruncated = false)
        assertEquals(1, builder.build().rows
            .filterIsInstance<TimelineRowUi.RunOutputGroup>().size)
        assertNull(builder.cachedRunOutputCard(run, "d".repeat(64)))
    }
}
