// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM tests for the R2 EDITABLE gate decisions and the new triage
 * parses. The R1 preview refusals are regression-covered by the untouched
 * CoolMessageGateTest in CoolMessageTriageTest.kt; nothing here weakens
 * them: every egress/authority route stays refused in BOTH modes.
 */
class CoolMessageEditGateTest {

    private fun editable(message: String) =
        CoolMessageGate.decide(message, CoolMessageGate.Mode.EDITABLE)

    private fun readOnly(message: String) =
        CoolMessageGate.decide(message, CoolMessageGate.Mode.READ_ONLY)

    @Test
    fun inPlaceSaveForwardsOnlyInEditableMode() {
        assertEquals(CoolMessageGate.Decision.FORWARD, editable("save dontTerminateEdit=1 dontSaveIfUnmodified=0").decision)
        // R1 preview refusal is unchanged.
        val preview = readOnly("save dontTerminateEdit=1 dontSaveIfUnmodified=1")
        assertEquals(CoolMessageGate.Decision.BLOCK_ROUTE, preview.decision)
        assertEquals("saveRouteUnavailable", preview.noticeKey)
    }

    @Test
    fun nativeSaveAckIsConsumedQuietlyAndNeverForwarded() {
        // The kit's postDirectMessage("SAVE <json>") shares the JS entry
        // point; forwarding it back into native would be wrong, and it is
        // never save proof (the page could forge the same string).
        val outcome = editable("SAVE {\"commandName\":\".uno:Save\",\"success\":true}")
        assertEquals(CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE, outcome.decision)
        assertNull(outcome.noticeKey)
    }

    @Test
    fun egressAndAuthorityRoutesStayRefusedInEditableMode() {
        for (message in listOf(
            "downloadas name=\"x.pdf\" id=export format=pdf options=",
            "exportfile url=file:///sdcard/x.pdf",
            "PRINT",
            "REQUESTFILECOPY",
            "saveas url=wopi:%2Fx",
            "exportas url=wopi:%2Fx",
            "savetostorage force=1",
            "renamefile filename=evil.docx",
            "insertfile name=file:///etc/passwd type=graphic",
            "versionrestore prerestore",
            "HYPERLINK https://evil.example/steal",
            "allowlinkupdate",
            "editwithpassword password=x",
            "executescript x",
            "proxyreturn x",
            "permissionmode edit",
        )) {
            assertEquals(message, CoolMessageGate.Decision.BLOCK_ROUTE, editable(message).decision)
        }
    }

    @Test
    fun macrosStayBlockedInEditableMode() {
        for (command in listOf(".uno:RunMacro", ".uno:MacroDialog", ".uno:MacroOrganizer", ".uno:SetPassword")) {
            val outcome = editable("uno $command")
            assertEquals(command, CoolMessageGate.Decision.BLOCK_MACRO, outcome.decision)
            assertEquals("macroBlocked", outcome.noticeKey)
        }
    }

    @Test
    fun ordinaryEditingCommandsForwardInEditableMode() {
        for (message in listOf(
            "uno .uno:Bold",
            "uno .uno:Undo",
            "uno .uno:Redo",
            "uno .uno:InsertText text=hello",
            "uno .uno:EditDoc?Editable:bool=true",
            "key type=input text=a",
            "mouse type=buttondown x=1 y=2",
            "setviewreadonly value=false",
            "setviewreadonly value=true",
            "contextmenu",
        )) {
            assertEquals(message, CoolMessageGate.Decision.FORWARD, editable(message).decision)
        }
    }

    @Test
    fun pageViewReadOnlyToggleStaysBlockedInPreviewOnly() {
        // The page's own pinned toggle must reach the kit in an editable
        // session (otherwise page and kit disagree — the stale-mismatch bug
        // class), while preview keeps refusing it.
        assertEquals(CoolMessageGate.Decision.FORWARD, editable("setviewreadonly value=false").decision)
        assertEquals(CoolMessageGate.Decision.BLOCK_ROUTE, readOnly("setviewreadonly value=false").decision)
    }

    @Test
    fun editDocIsBlockedInPreviewButForwardedWhenEditable() {
        assertEquals(CoolMessageGate.Decision.BLOCK_MACRO, readOnly("uno .uno:EditDoc").decision)
        assertEquals(CoolMessageGate.Decision.FORWARD, editable("uno .uno:EditDoc").decision)
    }

    @Test
    fun editModeMessagesAreConsumedNotForwarded() {
        assertEquals(CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE, editable("EDITMODE on").decision)
        assertEquals(CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE, editable("EDITMODE off").decision)
        // Preview keeps the honest refusal for an edit attempt.
        assertEquals(CoolMessageGate.Decision.BLOCK_ROUTE, readOnly("EDITMODE on").decision)
    }

    @Test
    fun backwardCompatibleBooleanOverloadMatchesModes() {
        assertEquals(
            CoolMessageGate.decide("save dontTerminateEdit=1", readOnly = false).decision,
            CoolMessageGate.decide("save dontTerminateEdit=1", CoolMessageGate.Mode.EDITABLE).decision,
        )
        assertEquals(
            CoolMessageGate.decide("save dontTerminateEdit=1", readOnly = true).decision,
            CoolMessageGate.decide("save dontTerminateEdit=1", CoolMessageGate.Mode.READ_ONLY).decision,
        )
    }
}

class CoolMessageTriageR2Test {

    private fun msg(text: String) = text.toByteArray(Charsets.UTF_8)

    @Test
    fun unocommandresultParsesTheSaveAck() {
        val result = CoolMessageTriage.classify(
            msg(
                """unocommandresult: {"commandName":".uno:Save","success":true,"result":{"type":"string","value":""},"isAutosave":false,"viewId":0}""",
            ),
        )
        assertEquals(CoolMessageTriage.Kind.UNO_COMMAND_RESULT, result.kind)
        assertEquals(".uno:Save", result.commandResult?.commandName)
        assertEquals(true, result.commandResult?.success)
        assertEquals(false, result.commandResult?.isAutosave)

        val unmodified = CoolMessageTriage.classify(
            msg(
                """unocommandresult: {"commandName":".uno:Save","success":false,"result":{"type":"string","value":"unmodified"}}""",
            ),
        )
        assertEquals(false, unmodified.commandResult?.success)
        assertEquals("unmodified", unmodified.commandResult?.resultValue)
        assertEquals(
            OfficeSaveProtocol.NativeSaveOutcome.UNMODIFIED_SKIPPED,
            OfficeSaveProtocol.outcome(unmodified.commandResult?.success, unmodified.commandResult?.resultValue),
        )

        // The wsd-stamped autosave flag is parsed.
        val autosave = CoolMessageTriage.classify(
            msg("""unocommandresult: {"commandName":".uno:Save","success":true,"isAutosave":true}"""),
        )
        assertEquals(true, autosave.commandResult?.isAutosave)

        // The desktop alias prefix classifies identically.
        assertEquals(
            CoolMessageTriage.Kind.UNO_COMMAND_RESULT,
            CoolMessageTriage.classify(msg("""commandresult: {"commandName":".uno:Save","success":true}""")).kind,
        )
    }

    @Test
    fun statechangedParsesBothPinnedWireShapes() {
        val json = CoolMessageTriage.classify(
            msg("""statechanged: {"commandName":".uno:ModifiedStatus","state":"true"}"""),
        )
        assertEquals(CoolMessageTriage.Kind.STATE_CHANGED, json.kind)
        assertEquals(".uno:ModifiedStatus", json.stateChange?.commandName)
        assertEquals("true", json.stateChange?.state)

        val pair = CoolMessageTriage.classify(msg("statechanged: .uno:Undo=false"))
        assertEquals(".uno:Undo", pair.stateChange?.commandName)
        assertEquals("false", pair.stateChange?.state)

        // The "enabled" alias is accepted (bundle.js reads either field).
        val enabled = CoolMessageTriage.classify(
            msg("""statechanged: {"commandName":".uno:Redo","enabled":"true"}"""),
        )
        assertEquals("true", enabled.stateChange?.state)

        // Garbage stays honest: kind without a fabricated witness.
        val broken = CoolMessageTriage.classify(msg("statechanged: "))
        assertEquals(CoolMessageTriage.Kind.STATE_CHANGED, broken.kind)
        assertNull(broken.stateChange)
    }

    @Test
    fun permAndFilemodeFramesAreTyped() {
        val perm = CoolMessageTriage.classify(msg("perm: edit"))
        assertEquals(CoolMessageTriage.Kind.PERM, perm.kind)
        assertEquals("edit", perm.perm)
        assertEquals("readonly", CoolMessageTriage.classify(msg("perm: readonly")).perm)
        // Unknown values never become a permission fact.
        assertNull(CoolMessageTriage.classify(msg("perm: owner")).perm)

        val fileMode = CoolMessageTriage.classify(
            msg("""filemode:{"readOnly": false, "editComment": true, "manageRedlines": false, "viewModeExtensions": ""}"""),
        )
        assertEquals(CoolMessageTriage.Kind.FILEMODE, fileMode.kind)
        assertEquals(false, fileMode.fileMode?.readOnly)
        assertEquals(true, fileMode.fileMode?.editComment)
        assertEquals(false, fileMode.fileMode?.manageRedlines)

        assertEquals(
            CoolMessageTriage.Kind.HAS_PASSWORD_TO_MODIFY,
            CoolMessageTriage.classify(msg("haspasswordtomodify: ")).kind,
        )
    }

    @Test
    fun errorFramesExposeCmdAndKind() {
        val saveError = CoolMessageTriage.classify(msg("error: cmd=storage kind=savefailed message=Could not save"))
        assertEquals(CoolMessageTriage.Kind.ERROR, saveError.kind)
        assertEquals("storage", saveError.error?.cmd)
        assertEquals("savefailed", saveError.error?.kind)
        assertTrue(OfficeSaveProtocol.isSaveRelatedError(saveError.error?.cmd, saveError.error?.kind))

        val sessionError = CoolMessageTriage.classify(msg("error: cmd=save kind=savefailed"))
        assertTrue(OfficeSaveProtocol.isSaveRelatedError(sessionError.error?.cmd, sessionError.error?.kind))

        val loadError = CoolMessageTriage.classify(msg("error: cmd=load kind=brokenfile"))
        assertFalse(OfficeSaveProtocol.isSaveRelatedError(loadError.error?.cmd, loadError.error?.kind))

        // R1-style payload without tokens still classifies, with null facts.
        val legacy = CoolMessageTriage.classify(msg("error: format-error.html"))
        assertEquals(CoolMessageTriage.Kind.ERROR, legacy.kind)
        assertNull(legacy.error?.cmd)
    }

    @Test
    fun r1ClassificationStaysIntact() {
        assertEquals(
            CoolMessageTriage.Kind.TILE_DELIVERY,
            CoolMessageTriage.classify(msg("tilecombine: 0;0;2;2")).kind,
        )
        assertEquals(
            CoolMessageTriage.Kind.STATUS,
            CoolMessageTriage.classify(msg("""status: {"width":8276,"height":11632}""")).kind,
        )
        assertNotNull(
            CoolMessageTriage.classify(msg("""status: {"width":8276,"height":11632}""")).shape,
        )
        // commandvalues stays out of the typed kinds (handled by the barrier
        // parser), and unknown prefixes remain OTHER.
        assertEquals(
            CoolMessageTriage.Kind.OTHER,
            CoolMessageTriage.classify(msg("""commandvalues: {"commandName":".uno:ReadOnly","success":false}""")).kind,
        )
    }
}

class OfficeRequestPolicyR2Test {

    @Test
    fun editPermissionIsAcceptedAtShapeLevel() {
        assertNull(
            OfficeRequestPolicy.validateShape(
                "tok", "/data/user/0/com.floe.agent/files/wc/document.docx",
                "a".repeat(64), 2048, "Doc", OfficePermission.EDIT,
            ),
        )
        // READ_ONLY shape rules are unchanged.
        assertNull(
            OfficeRequestPolicy.validateShape(
                "tok", "/data/user/0/com.floe.agent/files/snap/document.docx",
                "a".repeat(64), 2048, "Doc", OfficePermission.READ_ONLY,
            ),
        )
    }

    @Test
    fun factoryBuildsEditRequests() {
        val request = OfficePreviewRequest.of(
            sessionToken = "tok",
            stagedFilePath = "/data/user/0/com.floe.agent/files/wc/document.xlsx",
            sha256 = "b".repeat(64),
            lengthBytes = 4096,
            displayName = "Sheet",
            permission = OfficePermission.EDIT,
        )
        assertTrue(request.isSuccess)
        assertEquals(OfficePermission.EDIT, request.getOrNull()?.permission)
        assertEquals(OfficeDocumentFormat.XLSX, request.getOrNull()?.format)
        assertTrue(request.getOrNull()?.revalidated()?.isSuccess == true)
    }

    @Test
    fun saveRequestShapeFailsClosed() {
        val good = OfficeSaveRequest.of("op-1", "tok", 5L, OfficeSaveOperation.STAGED_EXPORT, format = "pdf")
        assertTrue(good.isSuccess)
        assertEquals("pdf", good.getOrNull()?.format)

        assertTrue(OfficeSaveRequest.of("op 1", "tok", 5L, OfficeSaveOperation.STAGED_EXPORT, format = "pdf").isFailure)
        assertTrue(OfficeSaveRequest.of("op-1", "tok", 0L, OfficeSaveOperation.STAGED_EXPORT, format = "pdf").isFailure)
        assertTrue(OfficeSaveRequest.of("op-1", "tok", 5L, OfficeSaveOperation.STAGED_EXPORT, format = "exe").isFailure)
        assertTrue(OfficeSaveRequest.of("op-1", "tok", 5L, OfficeSaveOperation.STAGED_EXPORT).isFailure)
        assertTrue(
            OfficeSaveRequest.of(
                "op-1", "tok", 5L, OfficeSaveOperation.WORKING_COPY_FLUSH, format = "pdf",
            ).isFailure,
        )
        assertTrue(
            OfficeSaveRequest.of(
                "op-1", "tok", 5L, OfficeSaveOperation.STAGED_EXPORT, format = "pdf",
                options = "TakeOwnership",
            ).isFailure,
        )
        assertTrue(
            OfficeSaveRequest.of(
                "op-1", "tok", 5L, OfficeSaveOperation.STAGED_EXPORT, format = "pdf",
                suggestedName = "evil|name",
            ).isFailure,
        )
        assertTrue(OfficeSaveRequest.of("op-1", "tok", 5L, OfficeSaveOperation.WORKING_COPY_FLUSH).isSuccess)
    }

    @Test
    fun stagedOutputVerificationIsReal() {
        val zipMagic = byteArrayOf(0x50, 0x4B, 0x03, 0x04)
        val good = createTempFile("floe-out", ".docx")
        good.writeBytes(zipMagic + "rest-of-container".toByteArray())
        val verified = OfficeRequestPolicy.verifyStagedOutput(good, "docx")
        assertTrue(verified.verified)
        assertEquals(good.length(), verified.bytes)
        assertEquals(64, verified.sha256?.length)

        val pdf = createTempFile("floe-out", ".pdf")
        pdf.writeBytes("%PDF-1.7\n...".toByteArray())
        assertTrue(OfficeRequestPolicy.verifyStagedOutput(pdf, "pdf").verified)

        val wrongType = createTempFile("floe-out", ".docx")
        wrongType.writeBytes("%PDF-1.7\n...".toByteArray())
        assertEquals(
            OfficeSaveFailureCode.OUTPUT_TYPE_MISMATCH,
            OfficeRequestPolicy.verifyStagedOutput(wrongType, "docx").failure,
        )

        val empty = createTempFile("floe-out", ".docx")
        assertEquals(
            OfficeSaveFailureCode.OUTPUT_EMPTY,
            OfficeRequestPolicy.verifyStagedOutput(empty, "docx").failure,
        )

        assertEquals(
            OfficeSaveFailureCode.OUTPUT_MISSING,
            OfficeRequestPolicy.verifyStagedOutput(java.io.File("/definitely/missing.docx"), "docx").failure,
        )

        good.delete(); pdf.delete(); wrongType.delete(); empty.delete()
    }

    @Test
    fun workingCopyDigestRereadRoundTrips() {
        val file = createTempFile("floe-wc", ".docx")
        val payload = "working copy bytes".toByteArray()
        file.writeBytes(payload)
        val digest = OfficeRequestPolicy.digestWorkingCopy(file)
        assertNotNull(digest)
        assertEquals(payload.size.toLong(), digest?.second)
        assertEquals(
            java.security.MessageDigest.getInstance("SHA-256").digest(payload)
                .joinToString("") { "%02x".format(it) },
            digest?.first,
        )
        assertNull(OfficeRequestPolicy.digestWorkingCopy(java.io.File("/definitely/missing.docx")))
        file.delete()
    }

    @Test
    fun exportFormatsMatchProducerSaveAsTokens() {
        // Mirrors the pinned upstream getFormatForRequestCode tokens narrowed
        // to this stage's qualified scope.
        assertEquals(
            setOf("docx", "xlsx", "pptx", "odt", "ods", "odp", "pdf"),
            OfficeRequestPolicy.EXPORT_FORMATS,
        )
        for (format in OfficeRequestPolicy.EXPORT_FORMATS) {
            assertTrue(format, OfficeRequestPolicy.expectedMagic(format).isNotEmpty())
        }
        assertEquals("%PDF-".toByteArray().toList(), OfficeRequestPolicy.expectedMagic("pdf").toList())
    }
}
