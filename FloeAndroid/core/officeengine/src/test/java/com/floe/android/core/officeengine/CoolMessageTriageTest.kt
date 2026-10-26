package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure JVM classification/gating rules pinned by the staged 26.04 mobile dist. */
class CoolMessageTriageTest {

    private fun msg(text: String) = text.toByteArray(Charsets.UTF_8)

    @Test
    fun progressMessageYieldsHonestDisplayFacts() {
        val result = CoolMessageTriage.classify(msg("""progress: {"id":"starttask","text":"Loading","value":31}"""))
        assertEquals(CoolMessageTriage.Kind.PROGRESS, result.kind)
        assertNotNull(result.progress)
        assertEquals("starttask", result.progress?.id)
        assertEquals("Loading", result.progress?.text)
        assertEquals(31, result.progress?.value)
    }

    @Test
    fun statusMessageYieldsDocumentShape() {
        val result = CoolMessageTriage.classify(
            msg("""status: {"commandName":"Status","width":8276,"height":11632}"""),
        )
        assertEquals(CoolMessageTriage.Kind.STATUS, result.kind)
        assertEquals(8276, result.shape?.widthTwip)
        assertEquals(11632, result.shape?.heightTwip)
    }

    @Test
    fun statusWithoutDimensionsHasNoWitness() {
        val result = CoolMessageTriage.classify(msg("status: {\"commandName\":\"Status\"}"))
        assertEquals(CoolMessageTriage.Kind.STATUS, result.kind)
        assertNull(result.shape)
    }

    @Test
    fun tileDeliveryPrefixesAreDistinctFromInvalidateRequests() {
        for (prefix in listOf(
            "tile: viewid=0 width=256 height=256",
            "tilecombine: 0;0;2;2",
            "delta: 0;0",
        )) {
            assertEquals(
                prefix,
                CoolMessageTriage.Kind.TILE_DELIVERY,
                CoolMessageTriage.classify(msg(prefix)).kind,
            )
        }
        // invalidatetiles is a redraw REQUEST: diagnostic only, never delivery.
        assertEquals(
            CoolMessageTriage.Kind.TILE_INVALIDATE,
            CoolMessageTriage.classify(msg("invalidatetiles: EMPTY")).kind,
        )
        // tileprop: must not masquerade as a tile delivery.
        assertEquals(
            CoolMessageTriage.Kind.OTHER,
            CoolMessageTriage.classify(msg("tileprop: whatever")).kind,
        )
    }

    @Test
    fun errorAndOtherPrefixes() {
        assertEquals(CoolMessageTriage.Kind.ERROR, CoolMessageTriage.classify(msg("error: format-error.html")).kind)
        assertEquals(CoolMessageTriage.Kind.PART_SET, CoolMessageTriage.classify(msg("setpart: commandvalue")).kind)
        assertEquals(
            CoolMessageTriage.Kind.STATE_CHANGED,
            CoolMessageTriage.classify(msg("statechanged: .uno:Save")).kind,
        )
        assertEquals(CoolMessageTriage.Kind.OTHER, CoolMessageTriage.classify(ByteArray(0)).kind)
    }
}

/** Transport-level R1 refusal decisions (NOT a kernel macro-policy claim). */
class CoolMessageGateTest {

    @Test
    fun hulloAndProtocolTrafficForwards() {
        assertEquals(CoolMessageGate.Decision.FORWARD, CoolMessageGate.decide("HULLO", readOnly = true).decision)
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            CoolMessageGate.decide("coolclient 0.1 1700000000 42", readOnly = true).decision,
        )
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            CoolMessageGate.decide(
                "load url=file:///data/user/0/com.floe.agent/files/snap/document.docx lang=en-US",
                readOnly = true,
            ).decision,
        )
    }

    @Test
    fun pageByeInterceptsForSettlement() {
        val bye = CoolMessageGate.decide("BYE", readOnly = true)
        assertEquals(CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE, bye.decision)
        assertEquals("bye", bye.noticeKey)
    }

    @Test
    fun saveExportEditHyperlinkPrintRoutesAreRefusedWithNotice() {
        for (message in listOf(
            "save dontTerminateEdit=1",
            "downloadas name=\"x.pdf\" type=pdf",
            "exportfile url=file:///tmp/x.pdf",
            "PRINT",
            "REQUESTFILECOPY",
            "HYPERLINK https://evil.example/steal",
        )) {
            val decision = CoolMessageGate.decide(message, readOnly = true)
            assertEquals(message, CoolMessageGate.Decision.BLOCK_ROUTE, decision.decision)
            assertNotNull(message, decision.noticeKey)
        }
    }

    @Test
    fun editModeOnIsRefusedButOffIsQuiet() {
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            CoolMessageGate.decide("EDITMODE on", readOnly = true).decision,
        )
        assertEquals(
            CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE,
            CoolMessageGate.decide("EDITMODE off", readOnly = true).decision,
        )
    }

    @Test
    fun macroCommandsAreBlockedAtTransportBoundary() {
        for (command in listOf(
            ".uno:RunMacro",
            ".uno:BasicIDEAppear",
            ".uno:MacroDialog",
            ".uno:OpenMacroDlg",
        )) {
            val decision = CoolMessageGate.decide("uno $command", readOnly = true)
            assertEquals(command, CoolMessageGate.Decision.BLOCK_MACRO, decision.decision)
            assertEquals("macroBlocked", decision.noticeKey)
        }
        // Ordinary view commands keep flowing to the kit.
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            CoolMessageGate.decide("uno .uno:Zoom", readOnly = true).decision,
        )
    }

    @Test
    fun unoSaveIsRefusedInReadonlyMode() {
        val decision = CoolMessageGate.decide("uno .uno:Save", readOnly = true)
        assertEquals(CoolMessageGate.Decision.BLOCK_ROUTE, decision.decision)
        assertEquals("saveRouteUnavailable", decision.noticeKey)
    }

    @Test
    fun clipboardCopyDetection() {
        assertTrue(CoolMessageGate.isClipboardCopyCommand("uno .uno:Copy"))
        assertTrue(CoolMessageGate.isClipboardCopyCommand("uno .uno:Cut"))
        assertFalse(CoolMessageGate.isClipboardCopyCommand("uno .uno:Paste"))
        assertFalse(CoolMessageGate.isClipboardCopyCommand("load url=x"))
    }

    @Test
    fun wizardAndPasswordFlows() {
        assertEquals(
            CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE,
            CoolMessageGate.decide("MOBILEWIZARD show", readOnly = true).decision,
        )
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            CoolMessageGate.decide("loadwithpassword password=x", readOnly = true).decision,
        )
    }
}

/** Pure bootstrap rules: marker identity + fonts.conf rewrite + safe paths. */
class OfficePayloadBootstrapTest {

    @Test
    fun markerChangesWithPayloadRevisionAndPackage() {
        val base = OfficePayloadBootstrap.unpackMarker("rev1", "com.floe.agent")
        assertEquals(base, OfficePayloadBootstrap.unpackMarker("rev1", "com.floe.agent"))
        assertTrue(OfficePayloadBootstrap.needsExtraction(base, "rev2", "com.floe.agent"))
        assertTrue(OfficePayloadBootstrap.needsExtraction(base, "rev1", "com.floe.agent.dev"))
        assertFalse(OfficePayloadBootstrap.needsExtraction(base, "rev1", "com.floe.agent"))
        assertTrue(OfficePayloadBootstrap.needsExtraction(null, "rev1", "com.floe.agent"))
    }

    @Test
    fun fontsConfRewriteTargetsRunningPackageOnly() {
        val staged = """
            <?xml version="1.0"?>
            <fontconfig>
            	<dir>/system/fonts</dir>
            	<cachedir>/data/data/com.collabora.libreoffice/fontconfig</cachedir>
            </fontconfig>
        """.trimIndent()
        val rewritten = OfficePayloadBootstrap.rewriteFontsConf(staged, "com.floe.agent")
        assertTrue(rewritten.contains("/data/data/com.floe.agent/fontconfig"))
        assertFalse(rewritten.contains("com.collabora.libreoffice"))
        // Other content untouched (idempotent for already-rewritten text).
        assertEquals(rewritten, OfficePayloadBootstrap.rewriteFontsConf(rewritten, "com.floe.agent"))
    }

    @Test
    fun unpackTargetPathsRefuseTraversal() {
        assertEquals("etc/fonts/fonts.conf", OfficePayloadBootstrap.unpackTargetRelPath("unpack/etc/fonts/fonts.conf"))
        assertNull(OfficePayloadBootstrap.unpackTargetRelPath("unpack/../escape"))
        assertNull(OfficePayloadBootstrap.unpackTargetRelPath("dist/cool.html"))
        assertNull(OfficePayloadBootstrap.unpackTargetRelPath("unpack/"))
    }
}

/** Parcel round-trip contract: read/write field order must be exact (Main review). */
class OfficePreviewRequestTest {

    private fun sample() = OfficePreviewRequest.of(
        sessionToken = "snap-session-1",
        stagedFilePath = "/data/data/com.floe.agent/files/snap/doc.docx",
        sha256 = "b".repeat(64),
        lengthBytes = 2048,
        displayName = "Snapshot doc",
        languageTag = "zh-CN",
        // workspace-less SAF local preview: everything optional stays null.
    ).getOrThrow()

    @Test
    fun factoryInfersFormatAndAcceptsOptionalNullIdentity() {
        val request = sample()
        assertEquals(OfficeDocumentFormat.DOCX, request.format)
        assertEquals(OfficePermission.READ_ONLY, request.permission)
        assertNull(request.workspaceId)
        assertNull(request.ownerTaskId)
        assertNull(request.sourceRevision)
    }

    @Test
    fun factoryRejectsOutOfRangeInputFailClosed() {
        assertTrue(
            OfficePreviewRequest.of(
                "tok", "/x/document.txt", "c".repeat(64), 10, "n",
            ).isFailure,
        )
        assertTrue(
            OfficePreviewRequest.of(
                "tok", "/x/document.docx", "C".repeat(64), 10, "n", // uppercase digest
            ).isFailure,
        )
        assertTrue(
            OfficePreviewRequest.of(
                "tok", "relative/document.docx", "c".repeat(64), 10, "n",
            ).isFailure,
        )
        assertTrue(
            OfficePreviewRequest.of(
                "tok", "/x/document.docx", "c".repeat(64), 0, "n",
            ).isFailure,
        )
    }

    @Test
    fun revalidationRefusesParcelWhereStatedFormatDisagreesWithStagedPath() {
        val tampered = sample().copy(format = OfficeDocumentFormat.XLSX)
        val outcome = tampered.revalidated()
        assertTrue(outcome.isFailure)
        assertEquals(
            OfficeFailureCode.UNSUPPORTED_FORMAT,
            (outcome.exceptionOrNull() as OfficeException).code,
        )
    }

    @Test
    fun revalidationAcceptsUntouchedShape() {
        assertTrue(sample().revalidated().isSuccess)
    }
}
