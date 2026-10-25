// SPDX-License-Identifier: MPL-2.0
//
// PROPOSED regression source (authored, NOT compiled or run — Main batches
// all checks per the G04R2 source-first policy).
//
// Queue-content repair coverage (job-e577557dec254fc9):
//  1. metadata-only/unread-body edit refusal (provenBodyVersion gate, body
//     slot preservation across the conversation.get lane, stale Ready
//     publish refusal);
//  2. 512-byte preview vs Unicode full text (previewComplete proof,
//     contentBytes labelling, COMPLETE never replaced by a preview);
//  3. truncated vs complete queue reconciliation (only proven-complete pages
//     retire, and only after TWO consecutive absent complete pages; a late
//     pre-change page cannot delete a newer row);
//  4. CAS-stale / retired epoch (a version move resets the body slot and
//     clears any published Ready; decode proves the row's exact CAS pair).
//
// Everything here is synthetic JSON — no store, network, provider or device.

package com.floe.android.host

import com.floe.android.feature.conversation.PendingInputBodyStateUi
import com.floe.android.feature.conversation.PendingInputBodyUi
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationPendingInputProjectionTest {

    private fun conversationPage(
        rows: List<JsonElement>,
        truncated: Boolean?,
        totalCount: Long?,
    ): JsonElement = JsonObject(
        buildMap {
            put("conversationID", JsonPrimitive("conv-1"))
            put("runs", JsonArray(emptyList()))
            put("pendingInputs", JsonArray(rows))
            truncated?.let { put("pendingInputsTruncated", JsonPrimitive(it)) }
            totalCount?.let { put("pendingInputsTotalCount", JsonPrimitive(it)) }
        },
    )

    private fun conversationRow(
        id: String,
        status: String = "queued",
        executionMode: String? = null,
        contentBytes: Long? = null,
    ): JsonElement = JsonObject(
        buildMap {
            put("id", JsonPrimitive(id))
            put("status", JsonPrimitive(status))
            put("mode", JsonPrimitive("queue"))
            put("position", JsonPrimitive(1))
            executionMode?.let { put("executionMode", JsonPrimitive(it)) }
            contentBytes?.let { put("contentBytes", JsonPrimitive(it)) }
        },
    )

    private fun snapshotPage(rows: List<JsonElement>, truncated: Boolean?): JsonElement =
        JsonObject(
            buildMap {
                put("runID", JsonPrimitive("run-1"))
                put("durableState", JsonPrimitive("streamingModel"))
                put(
                    "revision",
                    JsonObject(mapOf(
                        "resourceID" to JsonPrimitive("run.RUN-1"),
                        "version" to JsonPrimitive("streamingModel"),
                    )),
                )
                put("pendingInputs", JsonArray(rows))
                truncated?.let { put("pendingInputsTruncated", JsonPrimitive(it)) }
            },
        )

    private fun snapshotRow(
        id: String,
        inputVersion: String,
        preview: String? = null,
        previewComplete: Boolean? = null,
        contentBytes: Long? = null,
        executionMode: String? = null,
        status: String = "queued",
    ): JsonElement = JsonObject(
        buildMap {
            put("inputID", JsonPrimitive(id))
            put("inputVersion", JsonPrimitive(inputVersion))
            put("position", JsonPrimitive(1))
            put("status", JsonPrimitive(status))
            put("mode", JsonPrimitive("queue"))
            preview?.let { put("preview", JsonPrimitive(it)) }
            previewComplete?.let { put("previewComplete", JsonPrimitive(it)) }
            contentBytes?.let { put("contentBytes", JsonPrimitive(it)) }
            executionMode?.let { put("executionMode", JsonPrimitive(it)) }
        },
    )

    private fun builder() = ThreadProjectionBuilder("conv-1")

    // ---------------------------------------------------------------- wire

    @Test
    fun snapshotDecoderKeepsContentMembersAndCompleteness() {
        val page = ConversationWire.decodeSnapshotPage(
            snapshotPage(
                listOf(snapshotRow("in-1", "v1", preview = "hello", previewComplete = true,
                    contentBytes = 5, executionMode = "agent")),
                truncated = false,
            ),
        )
        assertNotNull(page)
        assertEquals(false, page!!.pendingInputsTruncated)
        val row = page.pendingInputs.single()
        assertEquals("hello", row.preview)
        assertEquals(true, row.previewComplete)
        assertEquals(5L, row.contentBytes)
        assertEquals("agent", row.executionModeRaw)
    }

    @Test
    fun legacyWireMembersDecodeToHonestAbsence() {
        val page = ConversationWire.decodeSnapshotPage(
            snapshotPage(listOf(snapshotRow("in-1", "v1")), truncated = null),
        )
        assertNotNull(page)
        assertNull(page!!.pendingInputsTruncated)
        val row = page.pendingInputs.single()
        assertNull(row.preview)
        assertNull(row.previewComplete)
        assertNull(row.contentBytes)
        assertNull(row.executionModeRaw)
        // Legacy page: the slot stays NOT_READ and no retirement authority.
        val b = builder()
        b.applySnapshot(page)
        val ui = b.build().pendingInputs.single()
        assertEquals(PendingInputBodyStateUi.NOT_READ, ui.bodyState)
        assertEquals("", ui.content)
    }

    @Test
    fun browserHandoffRowIsProjectedNotBlank() {
        val reply = ConversationWire.decodeSessionReply(
            conversationPage(listOf(conversationRow("in-1", executionMode = "browserHandoff",
                contentBytes = 200)), truncated = false, totalCount = 1),
        )!!
        assertEquals("browserHandoff", reply.pendingInputs.single().executionModeRaw)
        assertTrue(reply.pendingInputs.single().isBrowserHandoff)
        assertEquals(200L, reply.pendingInputs.single().contentBytes)
    }

    // ------------------------------------------------------- body precedence

    @Test
    fun shortRowPreviewCompletePromotesSlotToComplete() {
        val b = builder()
        b.applySnapshot(
            ConversationWire.decodeSnapshotPage(
                snapshotPage(
                    listOf(snapshotRow("in-1", "v1", preview = "短内容✓",
                        previewComplete = true, contentBytes = "短内容✓".toByteArray().size.toLong())),
                    truncated = false,
                ),
            )!!,
        )
        val row = b.build().pendingInputs.single()
        assertEquals("短内容✓", row.content)
        assertEquals(PendingInputBodyStateUi.COMPLETE, row.bodyState)
        // The proven version is editable without a detail read.
        assertEquals("v1", b.provenBodyVersion("in-1"))
    }

    @Test
    fun truncatedPreviewIsLabelledAndNotEditable() {
        val b = builder()
        b.applySnapshot(
            ConversationWire.decodeSnapshotPage(
                snapshotPage(
                    listOf(snapshotRow("in-1", "v1", preview = "五十…" , previewComplete = false,
                        contentBytes = 900)),
                    truncated = false,
                ),
            )!!,
        )
        val row = b.build().pendingInputs.single()
        assertEquals(PendingInputBodyStateUi.PREVIEW, row.bodyState)
        assertEquals(900L, row.contentBytes)
        assertNull(b.provenBodyVersion("in-1")) // editor stays read-locked
    }

    @Test
    fun completeSlotSurvivesPreviewAndMetadataPages() {
        val b = builder()
        b.applySnapshot(
            ConversationWire.decodeSnapshotPage(
                snapshotPage(listOf(snapshotRow("in-1", "v1", preview = "完整短句",
                    previewComplete = true, contentBytes = "完整短句".toByteArray().size.toLong())),
                    truncated = false),
            )!!,
        )
        // A later page carries only a bounded preview at the SAME version.
        b.applySnapshot(
            ConversationWire.decodeSnapshotPage(
                snapshotPage(listOf(snapshotRow("in-1", "v1", preview = "完整…",
                    previewComplete = false, contentBytes = 20000)), truncated = false),
            )!!,
        )
        val row = b.build().pendingInputs.single()
        assertEquals("完整短句", row.content)
        assertEquals(PendingInputBodyStateUi.COMPLETE, row.bodyState)
        // Metadata-only conversation page never clobbers the proven slot.
        b.applySession(
            ConversationWire.decodeSessionReply(
                conversationPage(listOf(conversationRow("in-1")), truncated = false, totalCount = 1),
            )!!,
        )
        assertEquals("完整短句", b.build().pendingInputs.single().content)
    }

    @Test
    fun versionMoveResetsBodySlotAndClearsPublishedReady() {
        val b = builder()
        b.applySnapshot(
            ConversationWire.decodeSnapshotPage(
                snapshotPage(listOf(snapshotRow("in-1", "v1", preview = "原文很长…" +
                    "x".repeat(4000), previewComplete = false, contentBytes = 4100)),
                    truncated = false),
            )!!,
        )
        assertTrue(b.applyPendingInputBody("in-1", "完整原始内容", "v1"))
        assertEquals("完整原始内容", b.build().pendingInputs.single().content)
        // The row moved underneath (e.g. edited on the other surface).
        b.applySnapshot(
            ConversationWire.decodeSnapshotPage(
                snapshotPage(listOf(snapshotRow("in-1", "v2", preview = "新的原文片段…",
                    previewComplete = false, contentBytes = 7777)), truncated = false),
            )!!,
        )
        val row = b.build().pendingInputs.single()
        assertEquals("新的原文片段…", row.content) // old full body NEVER kept
        assertEquals(PendingInputBodyStateUi.PREVIEW, row.bodyState)
        assertNull(b.pendingInputBody("in-1"))     // Ready cleared
        assertNull(b.provenBodyVersion("in-1"))
        assertFalse(b.applyPendingInputBody("in-1", "陈旧完整内容", "v1")) // stale publish refused
    }

    @Test
    fun unreadAndLoadingRowsHaveNoEditableBodyVersion() {
        val b = builder()
        b.applySession(
            ConversationWire.decodeSessionReply(
                conversationPage(listOf(conversationRow("in-1")), truncated = false, totalCount = 1),
            )!!,
        )
        assertNull(b.provenBodyVersion("in-1"))
        b.setPendingInputBody("in-1", PendingInputBodyUi.Loading)
        assertNull(b.provenBodyVersion("in-1"))
        b.setPendingInputBody("in-1", PendingInputBodyUi.Failed("notFound"))
        assertNull(b.provenBodyVersion("in-1"))
    }

    // ------------------------------------------------------------ retirement

    @Test
    fun truncatedPageKeepsUnknownRowsAndCannotRetire() {
        val b = builder()
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(listOf(snapshotRow("in-1", "v1")), truncated = false))!!)
        // A TRIMMED page without the row: the row is genuinely still durable
        // but simply outside the window — it must survive.
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(emptyList(), truncated = true))!!)
        assertEquals(1, b.build().pendingInputs.size)
    }

    @Test
    fun twoConsecutiveCompleteAbsentPagesRetireAGhostRow() {
        val b = builder()
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(listOf(snapshotRow("in-1", "v1", preview = "已发送的原文",
                previewComplete = true, contentBytes = 3)), truncated = false))!!)
        b.setPendingInputBody("in-1", PendingInputBodyUi.Ready("已发送的原文", "v1"))
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(emptyList(), truncated = false))!!)
        assertEquals("one absent page is only a candidate", 1, b.build().pendingInputs.size)
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(emptyList(), truncated = false))!!)
        assertTrue("two consecutive complete pages retire the ghost",
            b.build().pendingInputs.isEmpty())
        assertNull(b.pendingInputBody("in-1"))
    }

    @Test
    fun latePreChangePageCannotDeleteFreshlyQueuedRow() {
        val b = builder()
        // T0 page: queue empty (complete).
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(emptyList(), truncated = false))!!)
        // T1 page: the new row appears.
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(listOf(snapshotRow("in-2", "w1")), truncated = false))!!)
        // A LATE T0-issued complete page (without in-2) settles — candidate
        // only, NEVER a deletion.
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(emptyList(), truncated = false))!!)
        assertEquals(1, b.build().pendingInputs.size)
        // The NEXT fresh page proves the row again and clears the candidate.
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(listOf(snapshotRow("in-2", "w1")), truncated = false))!!)
        b.applySnapshot(ConversationWire.decodeSnapshotPage(
            snapshotPage(emptyList(), truncated = false))!!)
        assertEquals("row still present after one fresh page cleared the candidate",
            1, b.build().pendingInputs.size)
    }

    // ------------------------------------------------------------- body row

    @Test
    fun decodePendingInputBodyRowProvesExactCasPair() {
        val id = "11112222-3333-4444-5555-666677778888"
        val upper = id.uppercase()
        val row = JsonObject(mapOf(
            "id" to JsonPrimitive(upper),
            "conversationID" to JsonPrimitive("CONV"),
            "mode" to JsonPrimitive("queue"),
            "status" to JsonPrimitive("queued"),
            "position" to JsonPrimitive(1),
            "content" to JsonPrimitive("完整队列正文"),
            "contentUTF8Bytes" to JsonPrimitive(18),
            "executionMode" to JsonPrimitive("agent"),
            "attachmentCount" to JsonPrimitive(0),
            "inputVersion" to JsonPrimitive("2026-10-25T01:02:03.400Z"),
        ))
        val decoded = ConversationWire.decodePendingInputBodyRow(
            row, pageID = upper,
            pageRevisionResourceID = "pendingInput.$upper",
            pageRevisionVersion = "2026-10-25T01:02:03.400Z",
        )
        assertNotNull(decoded)
        assertEquals("完整队列正文", decoded!!.content)
        assertEquals("queued", decoded.statusRaw)
        // Foreign page identity, version skew or a wrong resource are ALL null.
        assertNull(ConversationWire.decodePendingInputBodyRow(row, pageID = "other",
            null, null))
        assertNull(ConversationWire.decodePendingInputBodyRow(row, upper, null, "older"))
        assertNull(ConversationWire.decodePendingInputBodyRow(row, upper,
            "pendingInput.LOWER-MISMATCH", "2026-10-25T01:02:03.400Z"))
    }
}
