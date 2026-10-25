// SPDX-License-Identifier: MPL-2.0
//
// PROPOSED regression source (authored, NOT compiled or run — Main batches
// all checks per the G04R2 source-first policy).
//
// Queue editor safety gate + display truthfulness (job-e577557dec254fc9):
// an unread row refuses Save, an open hydration refuses Save, only a
// published-Ready / native-proven-COMPLETE body dispatches `run.input.edit`,
// Cancel preserves, and the display vocabulary never renders a silently
// blank row or a preview without a label. Synthetic host only.

package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PendingInputEditorGateTest {

    private fun holder(host: RecordingHost, state: ThreadUiState): ConversationFlowHolder {
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(state)
        return holder
    }

    private fun row(
        id: String = "in-1",
        content: String = "",
        bodyState: PendingInputBodyStateUi = PendingInputBodyStateUi.NOT_READ,
        inputVersion: String? = null,
        executionMode: String = "agent",
    ) = PendingInputUi(
        id = id,
        content = content,
        status = PendingInputStatusUi.QUEUED,
        mode = RunningInputModeUi.QUEUE,
        executionModeRaw = executionMode,
        position = 1,
        bodyState = bodyState,
        inputVersion = inputVersion,
    )

    @Test
    fun unreadRowOpensEditorAndAsksHostForTheBoundedBodyRead() {
        val host = RecordingHost()
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row()),
        ))
        holder.openPendingInputEditor("in-1")
        assertEquals("in-1", holder.editingPendingInputId.value)
        // The unread original is never shown as an empty editable slot: the
        // display marker stands until the digest-verified read completes.
        assertEquals(PendingInputQueueLogic.BODY_UNREAD,
            PendingInputQueueLogic.displayText(row()))
    }

    @Test
    fun saveRefusesWhileBodyUnreadLoadingOrFailed() {
        for (body in listOf(
            null,
            PendingInputBodyUi.Loading,
            PendingInputBodyUi.Failed("detailRowUnreadable"),
        )) {
            val host = RecordingHost()
            val state = threadState(
                ConversationSessionToken("conv-1", 0L),
                pendingInputs = listOf(row()),
            ).let { if (body == null) it else it.copy(pendingInputBodies = mapOf("in-1" to body)) }
            val holder = holder(host, state)
            val result = holder.editPendingInput("in-1", "typed replacement")
            assertEquals("refuse Save for body=$body",
                ConversationFlowResult.Rejected(ConversationRejectedReason.INPUT_INSUFFICIENT),
                result)
            assertEquals(0, host.count("editPendingInput"))
        }
    }

    @Test
    fun saveRefusesWhenAPreviewIsAllThatArrived() {
        val host = RecordingHost()
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row(content = "五十…", bodyState = PendingInputBodyStateUi.PREVIEW,
                inputVersion = "v1")),
        ))
        assertNotEquals(PendingInputQueueLogic.BODY_UNREAD,
            PendingInputQueueLogic.displayText(row(content = "p", bodyState = PendingInputBodyStateUi.PREVIEW)))
        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.INPUT_INSUFFICIENT),
            holder.editPendingInput("in-1", "preview-length text"))
        assertEquals(0, host.count("editPendingInput"))
    }

    @Test
    fun saveDispatchesOnlyForAProvenCompleteBodyAtTheCurrentVersion() {
        val host = RecordingHost()
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row(content = "完整原始内容",
                bodyState = PendingInputBodyStateUi.COMPLETE, inputVersion = "v1")),
        ).copy(pendingInputBodies = mapOf("in-1" to PendingInputBodyUi.Ready("完整原始内容", "v1"))))
        holder.openPendingInputEditor("in-1")
        assertEquals(ConversationFlowResult.Accepted, holder.editPendingInput("in-1", "完整原始内容 改"))
        assertEquals(1, host.count("editPendingInput"))
        assertNull(holder.editingPendingInputId.value)
    }

    @Test
    fun nativeProvenShortRowIsEditableWithoutASecondRead() {
        val host = RecordingHost()
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row(content = "短内容✓",
                bodyState = PendingInputBodyStateUi.COMPLETE, inputVersion = "v1")),
        ))
        assertEquals(ConversationFlowResult.Accepted, holder.editPendingInput("in-1", "短内容✓ 改"))
        assertEquals(1, host.count("editPendingInput"))
    }

    @Test
    fun browserHandoffRowShowsTheTrustedNoticeNotABlankSlot() {
        val handoff = row(executionMode = "browserHandoff")
        assertEquals(PendingInputQueueLogic.BROWSER_HANDED_BACK,
            PendingInputQueueLogic.displayText(handoff))
    }

    // ------------------------------------------------------------------
    // C04 cold-load stranding regressions (queue-body-loading repair):
    // the sheet must never promise a load that is not in flight, and a
    // typed failure must stay retryable through the ordinary re-open.
    // ------------------------------------------------------------------

    @Test
    fun editorNoticeNeverPromisesLoadingForASlotNoReadOwns() {
        // The sheet's notice branch is pure logic: only a real owned
        // in-flight read (Loading slot) may render the loading promise.
        assertEquals(PendingInputQueueLogic.EditorNoticeKey.UNREAD,
            PendingInputQueueLogic.editorNoticeKey(null, hasPreview = false))
        assertEquals(PendingInputQueueLogic.EditorNoticeKey.LOADING,
            PendingInputQueueLogic.editorNoticeKey(PendingInputBodyUi.Loading, hasPreview = false))
        assertEquals(PendingInputQueueLogic.EditorNoticeKey.UNREAD,
            PendingInputQueueLogic.editorNoticeKey(
                PendingInputBodyUi.Failed("hostGenerationChanged"), hasPreview = false))
        assertEquals(PendingInputQueueLogic.EditorNoticeKey.UNREAD,
            PendingInputQueueLogic.editorNoticeKey(
                PendingInputBodyUi.Failed("operationSuperseded"), hasPreview = false))
        // A labelled preview still wins while the full body is unproven.
        assertEquals(PendingInputQueueLogic.EditorNoticeKey.PREVIEW,
            PendingInputQueueLogic.editorNoticeKey(
                PendingInputBodyUi.Failed("notFound"), hasPreview = true))
        assertEquals(PendingInputQueueLogic.EditorNoticeKey.PREVIEW,
            PendingInputQueueLogic.editorNoticeKey(null, hasPreview = true))
    }

    @Test
    fun hostRefusalLeavesNoLoadingPromiseAndTheRowHonest() {
        val host = RecordingHost() // pendingBodyReadAccepted defaults false
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row()),
        ))
        holder.openPendingInputEditor("in-1")
        // The open asked the host exactly once; the host refused. The slot
        // stays absent — the sheet renders the honest unread notice (never
        // an endless "Loading…" with no read behind it) and Save refuses.
        assertEquals(1, host.count("requestPendingInputBody"))
        assertNull(holder.snapshot.value!!.pendingInputBodies["in-1"])
        assertEquals(PendingInputQueueLogic.EditorNoticeKey.UNREAD,
            PendingInputQueueLogic.editorNoticeKey(
                holder.snapshot.value!!.pendingInputBodies["in-1"], hasPreview = false))
        assertEquals(PendingInputQueueLogic.BODY_UNREAD,
            PendingInputQueueLogic.displayText(row()))
        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.INPUT_INSUFFICIENT),
            holder.editPendingInput("in-1", "anything"))
        assertEquals(0, host.count("editPendingInput"))
    }

    @Test
    fun acceptedHostDispatchIsRecordedExactlyOncePerOpen() {
        val host = RecordingHost().apply { pendingBodyReadAccepted = true }
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row()),
        ))
        holder.openPendingInputEditor("in-1")
        assertEquals(1, host.count("requestPendingInputBody"))
        assertEquals("in-1", host.lastArgs("requestPendingInputBody")!![1])
    }

    @Test
    fun typedFailedSlotIsRetryableThroughTheOrdinaryReopen() {
        val host = RecordingHost().apply { pendingBodyReadAccepted = true }
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row()),
        ).copy(pendingInputBodies = mapOf(
            "in-1" to PendingInputBodyUi.Failed("hostGenerationChanged"))))
        // A typed failure is actionable: the ordinary re-open dispatches a
        // FRESH bounded read (a Failed slot is never treated as proven).
        holder.openPendingInputEditor("in-1")
        assertEquals(1, host.count("requestPendingInputBody"))
        // Save still refuses while the slot is Failed (no blank/preview
        // substitution ever reaches the durable row).
        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.INPUT_INSUFFICIENT),
            holder.editPendingInput("in-1", "anything"))
        assertEquals(0, host.count("editPendingInput"))
    }

    @Test
    fun provenReadySlotNeverRedispatchesOnReopen() {
        val host = RecordingHost().apply { pendingBodyReadAccepted = true }
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row(content = "完整原始内容",
                bodyState = PendingInputBodyStateUi.COMPLETE, inputVersion = "v1")),
        ).copy(pendingInputBodies = mapOf(
            "in-1" to PendingInputBodyUi.Ready("完整原始内容", "v1"))))
        holder.openPendingInputEditor("in-1")
        // Proven body binds directly; no redundant read is dispatched.
        assertEquals(0, host.count("requestPendingInputBody"))
    }

    @Test
    fun cancelKeepsTheUnreadRowProjected() {
        val host = RecordingHost()
        val holder = holder(host, threadState(
            ConversationSessionToken("conv-1", 0L),
            pendingInputs = listOf(row()),
        ))
        holder.openPendingInputEditor("in-1")
        holder.closePendingInputEditor()
        assertNull(holder.editingPendingInputId.value)
        assertEquals(1, holder.snapshot.value!!.pendingInputs.size)
        assertEquals(0, host.count("editPendingInput"))
        assertEquals(0, host.count("removePendingInput"))
    }
}
