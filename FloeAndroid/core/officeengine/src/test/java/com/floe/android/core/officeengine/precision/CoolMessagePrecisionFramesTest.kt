// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

import com.floe.android.core.officeengine.CoolMessageGate
import com.floe.android.core.officeengine.CoolMessageTriage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM regression for the precision-surface frame classifications added to
 * CoolMessageTriage (G05-R2 P-A) PLUS frozen-behaviour guards: the save
 * frame classifications and every gate decision the shipped manual-edit /
 * save protocol relies on must be byte-identical after this change.
 */
class CoolMessagePrecisionFramesTest {

    private fun classify(message: String) = CoolMessageTriage.classify(message.toByteArray(Charsets.UTF_8))

    // ------------------------------------------------------------------
    // New precision-frame classifications (pinned producer shapes)
    // ------------------------------------------------------------------

    @Test
    fun classifiesCommandValuesWithBoundedHeaderScalars() {
        val result = classify(
            "commandvalues: {\"commandName\":\".uno:CellCursor\",\"commandValues\":\"0, 380, 1219, 256, 1, 3\"}",
        )
        assertEquals(CoolMessageTriage.Kind.COMMAND_VALUE, result.kind)
        assertEquals(".uno:CellCursor", result.commandValue?.commandName)
        assertEquals("0, 380, 1219, 256, 1, 3", result.commandValue?.commandValues)

        // The barrier reply shape parses identically (commandName fence).
        val barrier = classify("commandvalues: {\"commandName\":\".uno:ReadOnly\",\"success\":false}")
        assertEquals(CoolMessageTriage.Kind.COMMAND_VALUE, barrier.kind)
        assertEquals(".uno:ReadOnly", barrier.commandValue?.commandName)

        // Object-shaped commandValues stay null (fail-closed).
        val obj = classify("commandvalues: {\"commandName\":\".uno:X\",\"commandValues\":{\"a\":1}}")
        assertEquals(".uno:X", obj.commandValue?.commandName)
        assertNull(obj.commandValue?.commandValues)

        // Malformed JSON header: kind classified, scalars fail closed.
        assertNull(classify("commandvalues: garbage").commandValue)
    }

    @Test
    fun classifiesSelectionAnswerAndComplexSelection() {
        assertEquals(
            CoolMessageTriage.Kind.TEXT_SELECTION_CONTENT,
            classify("textselectioncontent: hello").kind,
        )
        assertEquals(
            CoolMessageTriage.Kind.COMPLEX_SELECTION,
            classify("complexselection:").kind,
        )
        // Prefix hygiene: start/end cursor frames are NOT selection content
        // and are NOT the effect frame either (they stay OTHER).
        assertEquals(CoolMessageTriage.Kind.OTHER, classify("textselectionstart: {}").kind)
        assertEquals(CoolMessageTriage.Kind.OTHER, classify("textselectionend: {}").kind)
    }

    @Test
    fun classifiesPasteResultVerdicts() {
        val success = classify("pasteresult: success")
        assertEquals(CoolMessageTriage.Kind.PASTE_RESULT, success.kind)
        assertEquals("success", success.pasteVerdict)
        assertEquals("fallback", classify("pasteresult: fallback").pasteVerdict)
        // Unknown verdicts fail closed (kind kept, verdict null).
        assertNull(classify("pasteresult: maybe").pasteVerdict)
    }

    @Test
    fun classifiesPartEchoAndCalcPushFrames() {
        val part = classify("setpart: part=2")
        assertEquals(CoolMessageTriage.Kind.PART_SET, part.kind)
        assertEquals("2", part.part?.part)
        assertNull(classify("setpart: nonsense").part)
        assertEquals(CoolMessageTriage.Kind.CELL_CURSOR, classify("cellcursor: EMPTY").kind)
        assertEquals(CoolMessageTriage.Kind.CELL_ADDRESS, classify("celladdress: \$Sheet1.B2").kind)
        assertEquals(CoolMessageTriage.Kind.CELL_FORMULA, classify("cellformula: =SUM(A1)").kind)
        // Prefix hygiene: the view-cursor variants are distinct frames.
        assertEquals(CoolMessageTriage.Kind.OTHER, classify("cellviewcursor: 1, 2").kind)
        assertEquals(
            CoolMessageTriage.Kind.PRESENTATION_INFO,
            classify("presentationinfo: {\"slides\":{}}").kind,
        )
    }

    @Test
    fun classifiesSelectionEffectFrames() {
        assertEquals(CoolMessageTriage.Kind.TEXT_SELECTION, classify("textselection: 0, 0, 10, 10").kind)
        assertEquals(CoolMessageTriage.Kind.TEXT_SELECTION, classify("textselection: EMPTY").kind)
        assertEquals(
            CoolMessageTriage.Kind.GRAPHIC_SELECTION,
            classify("graphicselection: 0, 0, 10, 10").kind,
        )
        // The other-view variants are NOT the same frames.
        assertEquals(CoolMessageTriage.Kind.OTHER, classify("textviewselection: 1 x").kind)
        assertEquals(CoolMessageTriage.Kind.OTHER, classify("graphicviewselection: 1 x").kind)
    }

    // ------------------------------------------------------------------
    // Frozen behaviour guards (save/manual-edit protocol unchanged)
    // ------------------------------------------------------------------

    @Test
    fun saveFrameClassificationsAreUnchanged() {
        val saveAck = classify(
            "unocommandresult: {\"commandName\":\".uno:Save\",\"success\":true," +
                "\"result\":{\"type\":\"string\",\"value\":\"unmodified\"}}",
        )
        assertEquals(CoolMessageTriage.Kind.UNO_COMMAND_RESULT, saveAck.kind)
        assertEquals(".uno:Save", saveAck.commandResult?.commandName)
        assertEquals(true, saveAck.commandResult?.success)
        assertEquals("unmodified", saveAck.commandResult?.resultValue)

        val modified = classify("statechanged: .uno:ModifiedStatus=true")
        assertEquals(CoolMessageTriage.Kind.STATE_CHANGED, modified.kind)
        assertEquals(".uno:ModifiedStatus", modified.stateChange?.commandName)
        assertEquals("true", modified.stateChange?.state)

        val error = classify("error: cmd=save kind=savefailed")
        assertEquals(CoolMessageTriage.Kind.ERROR, error.kind)
        assertEquals("save", error.error?.cmd)
        assertEquals("savefailed", error.error?.kind)

        val status = classify("status: {\"width\":11906,\"height\":16838,\"partscount\":2}")
        assertEquals(CoolMessageTriage.Kind.STATUS, status.kind)
        assertEquals(11906, status.shape?.widthTwip)
        assertEquals(16838, status.shape?.heightTwip)
    }

    @Test
    fun gateDecisionsForManualEditAndSaveProtocolAreUnchanged() {
        // In-place save forwards only in editable mode.
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            CoolMessageGate.decide("save dontTerminateEdit=1 dontSaveIfUnmodified=0", CoolMessageGate.Mode.EDITABLE).decision,
        )
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            CoolMessageGate.decide("save dontTerminateEdit=1 dontSaveIfUnmodified=1", CoolMessageGate.Mode.READ_ONLY).decision,
        )
        // Keyboard framing: exactly one trailing LF stays protocol content.
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            CoolMessageGate.decide("key type=input char=97 key=0\n", CoolMessageGate.Mode.EDITABLE).decision,
        )
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            CoolMessageGate.decide("uno .uno:SelectAll\n", CoolMessageGate.Mode.EDITABLE).decision,
        )
        // Egress stays refused in BOTH modes.
        for (message in listOf("downloadas name=\"x\" format=pdf", "PRINT", "saveas url=wopi:%2Fx")) {
            assertEquals(
                CoolMessageGate.Decision.BLOCK_ROUTE,
                CoolMessageGate.decide(message, CoolMessageGate.Mode.EDITABLE).decision,
            )
            assertEquals(
                CoolMessageGate.Decision.BLOCK_ROUTE,
                CoolMessageGate.decide(message, CoolMessageGate.Mode.READ_ONLY).decision,
            )
        }
        // The native save ack is consumed quietly in editable mode.
        assertEquals(
            CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE,
            CoolMessageGate.decide("SAVE {\"commandName\":\".uno:Save\"}", CoolMessageGate.Mode.EDITABLE).decision,
        )
        // Page paste frames carry an embedded LF: they remain refused by the
        // frozen framing guard (precision paste is SERVICE-issued and never
        // routed through this gate).
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            CoolMessageGate.decide(
                "paste mimetype=text/plain;charset=utf-8\naGk=",
                CoolMessageGate.Mode.EDITABLE,
            ).decision,
        )
    }

    @Test
    fun hotPathPrefixesStayCheapAndOtherIsDefault() {
        assertEquals(CoolMessageTriage.Kind.TILE_DELIVERY, classify("tile: x=0 y=0").kind)
        assertEquals(CoolMessageTriage.Kind.TILE_INVALIDATE, classify("invalidatetiles: EMPTY").kind)
        assertEquals(CoolMessageTriage.Kind.PROGRESS, classify("progress: {\"id\":\"finish\"}").kind)
        assertEquals(CoolMessageTriage.Kind.PERM, classify("perm: edit").kind)
        assertEquals(CoolMessageTriage.Kind.FILEMODE, classify("filemode:{\"readOnly\":false}").kind)
        assertEquals(
            CoolMessageTriage.Kind.HAS_PASSWORD_TO_MODIFY,
            classify("haspasswordtomodify:").kind,
        )
        assertEquals(CoolMessageTriage.Kind.OTHER, classify("somefutureframe: x").kind)
        assertEquals(CoolMessageTriage.Kind.OTHER, classify("").kind)
        assertTrue(classify("statusupdate: {\"width\":1,\"height\":1}").shape != null)
    }
}
