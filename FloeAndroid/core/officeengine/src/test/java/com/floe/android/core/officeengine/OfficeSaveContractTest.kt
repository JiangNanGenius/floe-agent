// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM tests for the R2 save contract: the pinned protocol mapping
 * (common/SaveResult.hpp semantics), the coordinator state machine
 * (correlation, quarantine, cancel honesty) and the bounded RAM-only
 * diagnostics history. No Android framework behaviour is exercised.
 */
class OfficeSaveProtocolTest {

    @Test
    fun flushMessageMirrorsPinnedProtocol() {
        // Upstream parity: the official mobile app posts this exact shape.
        assertEquals(
            "save dontTerminateEdit=1 dontSaveIfUnmodified=1",
            OfficeSaveProtocol.flushMessage(saveIfUnmodified = true),
        )
        assertEquals(
            "save dontTerminateEdit=1 dontSaveIfUnmodified=0",
            OfficeSaveProtocol.flushMessage(saveIfUnmodified = false),
        )
    }

    @Test
    fun outcomeMappingFollowsPinnedSaveResultSemantics() {
        // success==true -> Saved, regardless of the result string.
        assertEquals(
            OfficeSaveProtocol.NativeSaveOutcome.WRITTEN,
            OfficeSaveProtocol.outcome(success = true, resultValue = null),
        )
        // success==false + "unmodified" -> honest no-op skip, NOT a failure
        // and NOT an arbitrary success.
        assertEquals(
            OfficeSaveProtocol.NativeSaveOutcome.UNMODIFIED_SKIPPED,
            OfficeSaveProtocol.outcome(success = false, resultValue = "unmodified"),
        )
        assertEquals(
            OfficeSaveProtocol.NativeSaveOutcome.FAILED,
            OfficeSaveProtocol.outcome(success = false, resultValue = null),
        )
        assertEquals(
            OfficeSaveProtocol.NativeSaveOutcome.FAILED,
            OfficeSaveProtocol.outcome(success = false, resultValue = "io-error"),
        )
        // An unparseable success field is never evidence.
        assertNull(OfficeSaveProtocol.outcome(success = null, resultValue = "unmodified"))
    }

    @Test
    fun exactEmptyResultSaveFailureFrameStaysNativeFailed() {
        // Byte shape observed on C07 at 17:37:32.644617: no result field.
        val frame = """unocommandresult: { "commandName": ".uno:Save", "success": false}"""
            .toByteArray(Charsets.UTF_8)
        val parsed = CoolMessageTriage.classify(frame).commandResult
        assertNotNull(parsed)
        assertEquals(false, parsed?.success)
        assertNull(parsed?.resultValue)

        val coordinator = OfficeSaveCoordinator()
        coordinator.submitFlush("op-empty-save", saveIfUnmodified = false)
        coordinator.markFlushDispatched("op-empty-save")
        coordinator.markSaveCommandDispatched("op-empty-save")
        val (outcome, external) = coordinator.onNativeSaveResult(
            commandName = parsed?.commandName ?: OfficeSaveProtocol.SAVE_COMMAND_NAME,
            success = parsed?.success,
            resultValue = parsed?.resultValue,
            isAutosave = parsed?.isAutosave == true,
        )
        assertNull(external)
        assertEquals(OfficeSaveCoordinator.FlushVerdict.NATIVE_FAILED, outcome?.verdict)
        assertNull(outcome?.detail)
    }

    @Test
    fun saveErrorFramesAreDistinguishedFromLoadErrors() {
        assertTrue(OfficeSaveProtocol.isSaveRelatedError("save", "savefailed"))
        assertTrue(OfficeSaveProtocol.isSaveRelatedError("storage", "savefailed"))
        assertFalse(OfficeSaveProtocol.isSaveRelatedError("storage", "diskfull"))
        assertFalse(OfficeSaveProtocol.isSaveRelatedError("load", "savefailed"))
        assertFalse(OfficeSaveProtocol.isSaveRelatedError(null, null))
    }
}

class OfficeSaveCoordinatorTest {

    private fun dispatchSave(coordinator: OfficeSaveCoordinator, opId: String) {
        assertTrue(coordinator.markFlushDispatched(opId))
        assertTrue(coordinator.markSaveCommandDispatched(opId))
    }

    @Test
    fun singleFlushCorrelationAndBusyRefusal() {
        val coordinator = OfficeSaveCoordinator()
        assertEquals(
            OfficeSaveCoordinator.SubmitDecision.ACCEPTED,
            coordinator.submitFlush("op-1", saveIfUnmodified = false),
        )
        assertEquals(
            OfficeSaveCoordinator.SubmitDecision.REJECTED_BUSY,
            coordinator.submitFlush("op-2", saveIfUnmodified = false),
        )
        assertTrue(coordinator.markFlushDispatched("op-1"))
        assertFalse(coordinator.markFlushDispatched("op-other"))
        assertTrue(coordinator.markSaveCommandDispatched("op-1"))

        val (outcome, external) = coordinator.onNativeSaveResult(
            commandName = ".uno:Save", success = true, resultValue = null, isAutosave = false,
        )
        assertNotNull(outcome)
        assertNull(external)
        assertEquals("op-1", outcome?.opId)
        assertEquals(OfficeSaveCoordinator.FlushVerdict.WRITTEN_ACK, outcome?.verdict)

        // After settlement the next flush is accepted again, and an ack with
        // no pending op is an external record — it never completes a new op.
        assertEquals(
            OfficeSaveCoordinator.SubmitDecision.ACCEPTED,
            coordinator.submitFlush("op-3", saveIfUnmodified = false),
        )
        val (none, ext) = coordinator.onNativeSaveResult(
            commandName = ".uno:Undo", success = true, resultValue = null, isAutosave = false,
        )
        assertNull(none)
        assertNull(ext) // not a save command at all
        assertEquals("op-3", coordinator.pendingFlushOpId())
    }

    @Test
    fun unmodifiedAndFailedVerdictsMapExactly() {
        val coordinator = OfficeSaveCoordinator()
        coordinator.submitFlush("op-u", saveIfUnmodified = true)
        dispatchSave(coordinator, "op-u")
        val (unmodified, _) = coordinator.onNativeSaveResult(".uno:Save", false, "unmodified", false)
        assertEquals(OfficeSaveCoordinator.FlushVerdict.UNMODIFIED, unmodified?.verdict)

        coordinator.submitFlush("op-f", saveIfUnmodified = false)
        dispatchSave(coordinator, "op-f")
        val (failed, _) = coordinator.onNativeSaveResult(".uno:Save", false, "io-error", false)
        assertEquals(OfficeSaveCoordinator.FlushVerdict.NATIVE_FAILED, failed?.verdict)
        assertEquals("io-error", failed?.detail)
    }

    @Test
    fun externalSaveWithoutPendingOpIsRecordedNotApplied() {
        val coordinator = OfficeSaveCoordinator()
        val (outcome, external) = coordinator.onNativeSaveResult(".uno:Save", true, null, false)
        assertNull(outcome)
        assertNotNull(external)
        assertEquals(OfficeSaveCoordinator.FlushVerdict.WRITTEN_ACK, external?.verdict)
        assertFalse(external!!.isAutosave)
    }

    @Test
    fun saveAckBeforeActualSaveCommandStaysExternalThroughEditDispatch() {
        val coordinator = OfficeSaveCoordinator()
        coordinator.submitFlush("op-edit-prep", saveIfUnmodified = false)

        val (preparationOutcome, preparationExternal) =
            coordinator.onNativeSaveResult(".uno:Save", true, null, false)
        assertNull(preparationOutcome)
        assertEquals(
            OfficeSaveCoordinator.FlushVerdict.WRITTEN_ACK,
            preparationExternal?.verdict,
        )
        assertEquals("op-edit-prep", coordinator.pendingFlushOpId())

        // Native setviewreadonly dispatch has started for cancellation
        // purposes, but the REAL save command still has not been sent.
        coordinator.markFlushDispatched("op-edit-prep")
        val (editOutcome, editExternal) =
            coordinator.onNativeSaveResult(".uno:Save", false, "unmodified", true)
        assertNull(editOutcome)
        assertEquals(
            OfficeSaveCoordinator.FlushVerdict.UNMODIFIED,
            editExternal?.verdict,
        )
        assertEquals(true, editExternal?.isAutosave)
        assertEquals("op-edit-prep", coordinator.pendingFlushOpId())

        dispatchSave(coordinator, "op-edit-prep")
        val (hostOutcome, hostExternal) =
            coordinator.onNativeSaveResult(".uno:Save", true, null, false)
        assertNull(hostExternal)
        assertEquals(OfficeSaveCoordinator.FlushVerdict.WRITTEN_ACK, hostOutcome?.verdict)
        assertNull(coordinator.pendingFlushOpId())
    }

    @Test
    fun saveErrorBeforeActualSaveCommandDoesNotSettlePendingFlush() {
        val coordinator = OfficeSaveCoordinator()
        coordinator.submitFlush("op-edit-error", saveIfUnmodified = false)
        coordinator.markFlushDispatched("op-edit-error")
        assertNull(coordinator.onSaveErrorFrame("storage", "savefailed"))
        assertEquals("op-edit-error", coordinator.pendingFlushOpId())

        coordinator.markSaveCommandDispatched("op-edit-error")
        val outcome = coordinator.onSaveErrorFrame("storage", "savefailed")
        assertEquals(OfficeSaveCoordinator.FlushVerdict.NATIVE_FAILED, outcome?.verdict)
        assertNull(coordinator.pendingFlushOpId())
    }

    @Test
    fun autosaveCollisionIsNeverAttributedAndQuarantinesFlushes() {
        val coordinator = OfficeSaveCoordinator()
        coordinator.submitFlush("op-1", saveIfUnmodified = false)
        dispatchSave(coordinator, "op-1")
        val (outcome, external) = coordinator.onNativeSaveResult(".uno:Save", true, null, true)
        assertNull(external)
        assertEquals(OfficeSaveCoordinator.FlushVerdict.NO_PROOF, outcome?.verdict)
        assertEquals("autosave-ack-collision", outcome?.detail)
        assertTrue(coordinator.isStaleFlushAckPossible())
        // A late stale ack can never satisfy a NEW operation: flushes are
        // refused for this mount...
        assertEquals(
            OfficeSaveCoordinator.SubmitDecision.REJECTED_STALE_ACK_RISK,
            coordinator.submitFlush("op-2", saveIfUnmodified = false),
        )
        // ...while the synchronous export path (no ack correlation) stays
        // available (Main contract 2026-10-26).
        assertTrue(coordinator.beginExport("export-1"))
    }

    @Test
    fun timeoutIsUnknownAndQuarantines() {
        val coordinator = OfficeSaveCoordinator()
        coordinator.submitFlush("op-1", saveIfUnmodified = false)
        dispatchSave(coordinator, "op-1")
        // A timeout for a different op changes nothing.
        assertNull(coordinator.onTimeout("op-other"))
        val outcome = coordinator.onTimeout("op-1")
        assertEquals(OfficeSaveCoordinator.FlushVerdict.NO_PROOF, outcome?.verdict)
        assertEquals("timeout-without-ack", outcome?.detail)
        assertTrue(coordinator.isStaleFlushAckPossible())
        // The late real ack afterwards is external, never a new op's proof.
        val (none, external) = coordinator.onNativeSaveResult(".uno:Save", true, null, false)
        assertNull(none)
        assertNotNull(external)
    }

    @Test
    fun saveErrorFramesCompletePendingFlushOnly() {
        val coordinator = OfficeSaveCoordinator()
        // Unrelated error frames are ignored.
        assertNull(coordinator.onSaveErrorFrame("load", "passwordrequired:to-view"))
        coordinator.submitFlush("op-1", saveIfUnmodified = false)
        dispatchSave(coordinator, "op-1")
        val outcome = coordinator.onSaveErrorFrame("storage", "savefailed")
        assertEquals(OfficeSaveCoordinator.FlushVerdict.NATIVE_FAILED, outcome?.verdict)
        assertEquals("error:cmd=storage kind=savefailed", outcome?.detail)
        assertNull(coordinator.pendingFlushOpId())
    }

    @Test
    fun cancelIsHonouredOnlyBeforeDispatch() {
        val coordinator = OfficeSaveCoordinator()
        assertEquals(
            OfficeSaveCoordinator.CancelDecision.UNKNOWN_OP,
            coordinator.requestCancel("op-none"),
        )
        coordinator.submitFlush("op-1", saveIfUnmodified = false)
        assertEquals(
            OfficeSaveCoordinator.CancelDecision.CANCELLED_BEFORE_DISPATCH,
            coordinator.requestCancel("op-1"),
        )
        assertNull(coordinator.pendingFlushOpId())

        // After dispatch there is NO native cancel: the op stays pending and
        // the flag only marks the eventual receipt.
        coordinator.submitFlush("op-2", saveIfUnmodified = false)
        coordinator.markFlushDispatched("op-2")
        coordinator.markSaveCommandDispatched("op-2")
        assertEquals(
            OfficeSaveCoordinator.CancelDecision.STILL_IN_FLIGHT,
            coordinator.requestCancel("op-2"),
        )
        assertEquals("op-2", coordinator.pendingFlushOpId())
        val (outcome, _) = coordinator.onNativeSaveResult(".uno:Save", true, null, false)
        assertEquals("op-2", outcome?.opId)
        assertTrue(outcome!!.cancelRequested)
    }

    @Test
    fun mountTerminalSettlesPendingFlushAsUnknown() {
        val coordinator = OfficeSaveCoordinator()
        assertNull(coordinator.onMountTerminal())
        coordinator.submitFlush("op-1", saveIfUnmodified = false)
        coordinator.markFlushDispatched("op-1")
        val outcome = coordinator.onMountTerminal()
        assertEquals(OfficeSaveCoordinator.FlushVerdict.NO_PROOF, outcome?.verdict)
        assertEquals("mount-ended-without-ack", outcome?.detail)
    }

    @Test
    fun dispatchFailureIsHonestFailureNotUnknown() {
        val coordinator = OfficeSaveCoordinator()
        coordinator.submitFlush("op-1", saveIfUnmodified = false)
        val outcome = coordinator.abortDispatch("op-1", "UnsatisfiedLinkError")
        assertEquals(OfficeSaveCoordinator.FlushVerdict.DISPATCH_FAILED, outcome?.verdict)
        assertNull(coordinator.pendingFlushOpId())
        // A dispatch failure did not reach the kit: no stale-ack risk.
        assertFalse(coordinator.isStaleFlushAckPossible())
        assertEquals(
            OfficeSaveCoordinator.SubmitDecision.ACCEPTED,
            coordinator.submitFlush("op-2", saveIfUnmodified = false),
        )
    }

    @Test
    fun exportSerializationAndCancelFlag() {
        val coordinator = OfficeSaveCoordinator()
        assertTrue(coordinator.beginExport("export-1"))
        assertFalse(coordinator.beginExport("export-2"))
        assertEquals(
            OfficeSaveCoordinator.CancelDecision.STILL_IN_FLIGHT,
            coordinator.requestCancel("export-1"),
        )
        assertTrue(coordinator.isExportCancelRequested("export-1"))
        assertFalse(coordinator.isExportCancelRequested("export-2"))
        coordinator.endExport("export-1")
        assertFalse(coordinator.isExportCancelRequested("export-1"))
        assertTrue(coordinator.beginExport("export-2"))
    }
}

class OfficeSessionDiagnosticsTest {

    @Test
    fun recordsInOrderAndSnapshots() {
        val diagnostics = OfficeSessionDiagnostics()
        diagnostics.record(1000L, OfficeSessionDiagnostics.KIND_JS_ERROR, "first")
        diagnostics.record(2000L, OfficeSessionDiagnostics.KIND_NOTICE, "second")
        val snapshot = diagnostics.snapshot()
        assertEquals(2, snapshot.size)
        assertEquals("first", snapshot[0].detail)
        assertEquals(OfficeSessionDiagnostics.KIND_NOTICE, snapshot[1].kind)
        assertEquals(2000L, snapshot[1].elapsedRealtimeMs)
    }

    @Test
    fun startupErrorsSurviveLaterGenericNoticesWithinBounds() {
        // The R1 C8 lesson: two early js-error events must still be present
        // after many later notices — bounded eviction only drops the OLDEST
        // entries once the cap is exceeded.
        val diagnostics = OfficeSessionDiagnostics()
        diagnostics.record(1L, OfficeSessionDiagnostics.KIND_JS_ERROR, "startup-error-1")
        diagnostics.record(2L, OfficeSessionDiagnostics.KIND_JS_ERROR, "startup-error-2")
        for (i in 1..20) diagnostics.record(10L + i, OfficeSessionDiagnostics.KIND_NOTICE, "notice-$i")
        val kinds = diagnostics.snapshot().map { it.detail }
        assertTrue(kinds.contains("startup-error-1"))
        assertTrue(kinds.contains("startup-error-2"))
    }

    @Test
    fun countBoundEvictsOldest() {
        val diagnostics = OfficeSessionDiagnostics(maxEvents = 3)
        for (i in 1..5) diagnostics.record(i.toLong(), "state", "e$i")
        val snapshot = diagnostics.snapshot()
        assertEquals(3, snapshot.size)
        assertEquals(listOf("e3", "e4", "e5"), snapshot.map { it.detail })
    }

    @Test
    fun byteBoundEvictsOldest() {
        // 3 entries x 10 chars = 30 total budget; each detail is 10 chars.
        val diagnostics = OfficeSessionDiagnostics(maxEvents = 64, maxTotalDetailChars = 30, maxDetailChars = 20)
        diagnostics.record(1L, "k", "0123456789")
        diagnostics.record(2L, "k", "abcdefghij")
        diagnostics.record(3L, "k", "ABCDEFGHIJ")
        diagnostics.record(4L, "k", "klmnopqrst")
        val snapshot = diagnostics.snapshot()
        assertTrue(snapshot.size <= 3)
        assertEquals("klmnopqrst", snapshot.last().detail)
        assertFalse(snapshot.any { it.detail == "0123456789" })
    }

    @Test
    fun detailIsTruncatedAndControlCharsScrubbed() {
        val diagnostics = OfficeSessionDiagnostics(maxDetailChars = 12)
        diagnostics.record(1L, "js-error", "line1\nline2\ttabbed\u0000plus-more-than-twelve")
        val detail = diagnostics.snapshot().single().detail
        assertEquals(12, detail.length)
        assertFalse(detail.any { it.code < 0x20 || it.code == 0x7f })
    }

    @Test
    fun kindIsSanitizedAndBounded() {
        val diagnostics = OfficeSessionDiagnostics()
        diagnostics.record(1L, "weird kind!?<>\u0000", null)
        assertEquals("weirdkind", diagnostics.snapshot().single().kind)
        diagnostics.record(2L, "", "x")
        assertEquals("event", diagnostics.snapshot().last().kind)
    }
}

class OfficeHostSaveHandoffPolicyTest {

    @Test
    fun opIdBoundsAndCharset() {
        assertTrue(OfficeHostSaveHandoffPolicy.validOpId("export-1-abcDEF_0"))
        assertTrue(OfficeHostSaveHandoffPolicy.validOpId("a".repeat(64)))
        assertFalse(OfficeHostSaveHandoffPolicy.validOpId("a".repeat(65)))
        assertFalse(OfficeHostSaveHandoffPolicy.validOpId(""))
        assertFalse(OfficeHostSaveHandoffPolicy.validOpId(null))
        assertFalse(OfficeHostSaveHandoffPolicy.validOpId("op|pipe"))
        assertFalse(OfficeHostSaveHandoffPolicy.validOpId("op space"))
        assertFalse(OfficeHostSaveHandoffPolicy.validOpId("op/path"))
    }

    @Test
    fun formatAllowlist() {
        for (format in listOf("docx", "xlsx", "pptx", "odt", "ods", "odp", "pdf")) {
            assertTrue(format, OfficeHostSaveHandoffPolicy.validFormat(format))
        }
        assertFalse(OfficeHostSaveHandoffPolicy.validFormat("exe"))
        assertFalse(OfficeHostSaveHandoffPolicy.validFormat("DOCX"))
        assertFalse(OfficeHostSaveHandoffPolicy.validFormat(null))
    }

    @Test
    fun suggestedNameAndUriStayInert() {
        assertTrue(OfficeHostSaveHandoffPolicy.validSuggestedName(null))
        assertTrue(OfficeHostSaveHandoffPolicy.validSuggestedName("Quarterly report.docx"))
        assertFalse(OfficeHostSaveHandoffPolicy.validSuggestedName(""))
        assertFalse(OfficeHostSaveHandoffPolicy.validSuggestedName("a/b"))
        assertFalse(OfficeHostSaveHandoffPolicy.validSuggestedName("a\\b"))
        assertFalse(OfficeHostSaveHandoffPolicy.validSuggestedName("a|b"))
        assertFalse(OfficeHostSaveHandoffPolicy.validSuggestedName("a".repeat(241)))
        assertTrue(OfficeHostSaveHandoffPolicy.validUriString(null))
        assertTrue(OfficeHostSaveHandoffPolicy.validUriString("content://com.example/tree/1"))
        assertFalse(OfficeHostSaveHandoffPolicy.validUriString("a".repeat(4097)))
        assertFalse(OfficeHostSaveHandoffPolicy.validUriString("line\nbreak"))
    }

    @Test
    fun prepareAndPickResultValidationFailsClosed() {
        assertNotNull(
            OfficeHostSaveHandoffPolicy.validatePrepare("op-1", "tok", 3L, "pdf", "name.pdf"),
        )
        assertNull(OfficeHostSaveHandoffPolicy.validatePrepare("op 1", "tok", 3L, "pdf", null))
        assertNull(OfficeHostSaveHandoffPolicy.validatePrepare("op-1", "tok", 0L, "pdf", null))
        assertNull(OfficeHostSaveHandoffPolicy.validatePrepare("op-1", "tok", 3L, "exe", null))
        val result = OfficeHostSaveHandoffPolicy.validatePickResult(
            "op-1", "tok", 3L, -1, "content://x", 3,
        )
        assertNotNull(result)
        assertEquals(-1, result?.resultCode)
        assertNull(
            OfficeHostSaveHandoffPolicy.validatePickResult("op-1", "tok", 3L, 1, "a\u0000b", 0),
        )
    }
}

class OfficeSaveReceiptDescriptorTest {

    private fun receipt() = OfficeSaveReceipt(
        opId = "export-1",
        sessionToken = "tok",
        generation = 7L,
        operation = OfficeSaveOperation.STAGED_EXPORT,
        state = OfficeSaveState.OUTPUT_READY,
        format = "docx",
        suggestedName = "report.docx",
        expectedBaseSha256 = "a".repeat(64),
        workingCopySha256 = null,
        workingCopyBytes = 0L,
        outputDocumentPath = "/data/user/0/com.floe.agent/no_backup/floe-office-outputs/7/export-1-123.docx",
        outputSha256 = "b".repeat(64),
        outputBytes = 4096L,
        failure = null,
        message = null,
        cancelRequested = false,
        attestation = "jni-saveas-sync+output-verified",
        submittedAtElapsedMs = 100L,
        completedAtElapsedMs = 900L,
    )

    @Test
    fun descriptorRoundTripsThroughActivityResultShape() {
        val line = receipt().descriptorLine()
        assertFalse(line.contains("\n"))
        val parsed = OfficeSaveReceipt.fromDescriptorLine(line)
        assertNotNull(parsed)
        assertEquals("export-1", parsed?.opId)
        assertEquals(OfficeSaveOperation.STAGED_EXPORT, parsed?.operation)
        assertEquals(OfficeSaveState.OUTPUT_READY, parsed?.state)
        assertEquals("docx", parsed?.format)
        assertEquals(4096L, parsed?.outputBytes)
        assertEquals("b".repeat(64), parsed?.outputSha256)
        assertEquals(900L, parsed?.completedAtElapsedMs)
    }

    @Test
    fun malformedDescriptorFailsClosed() {
        assertNull(OfficeSaveReceipt.fromDescriptorLine("too|few"))
        assertNull(OfficeSaveReceipt.fromDescriptorLine(receipt().descriptorLine() + "|extra"))
        val broken = receipt().descriptorLine().replace("OUTPUT_READY", "NOT_A_STATE")
        assertNull(OfficeSaveReceipt.fromDescriptorLine(broken))
    }
}
