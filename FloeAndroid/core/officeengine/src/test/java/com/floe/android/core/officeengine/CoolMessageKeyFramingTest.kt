// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Focused regressions for the narrow trailing-LF keyboard-frame parity
 * (G05-R2, 2026-10-26). The pinned mobile bundle terminates ONLY its
 * `key`/`windowkey` frames with one trailing LF (TextInput.js
 * `_sendKeyEvent`), and upstream forwards those frames to the kit
 * verbatim; the previous blanket LF refusal dropped every keyboard
 * command and surfaced the misleading preview notice. Authored here,
 * NOT RUN — Main runs the grouped JVM pass. Nothing weakens preview
 * denial: mode dispatch, allowlists and egress refusals are unchanged.
 */
class CoolMessageKeyFramingTest {

    private fun editable(message: String) =
        CoolMessageGate.decide(message, CoolMessageGate.Mode.EDITABLE)

    private fun readOnly(message: String) =
        CoolMessageGate.decide(message, CoolMessageGate.Mode.READ_ONLY)

    @Test
    fun trailingLfKeyFramesForwardInEditableMode() {
        // The exact dropped frames from the actual session (Enter, Ctrl+A, up).
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            editable("key type=input char=13 key=1280\n").decision,
        )
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            editable("key type=input char=0 key=8704\n").decision,
        )
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            editable("key type=up char=0 key=1280\n").decision,
        )
    }

    @Test
    fun trailingLfWindowKeyFrameForwards() {
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            editable("windowkey id=1 type=input char=13 key=1280\n").decision,
        )
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            readOnly("windowkey id=2 type=up char=0 key=8704\n").decision,
        )
    }

    @Test
    fun trailingLfKeyFrameStillForwardsInPreviewMode() {
        // `key` was already forwarded without LF in preview (allowlist);
        // the LF parity fix must not change preview forwarding or any
        // authority: read-only truth stays gated by the native
        // barrier/perm/filemode witnesses, untouched by the gate.
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            readOnly("key type=input char=97 key=97\n").decision,
        )
    }

    @Test
    fun frameWithoutLfIsUnaffected() {
        assertEquals(
            CoolMessageGate.Decision.FORWARD,
            editable("key type=input char=13 key=1280").decision,
        )
    }

    @Test
    fun embeddedNewlineKeyFrameStaysRefused() {
        val embedded = "key type=input char=0\nkey=8704"
        assertEquals(CoolMessageGate.Decision.BLOCK_ROUTE, editable(embedded).decision)
        assertEquals(CoolMessageGate.Decision.BLOCK_ROUTE, readOnly(embedded).decision)
    }

    @Test
    fun carriageReturnKeyFrameStaysRefused() {
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            editable("key type=input char=13 key=1280\r\n").decision,
        )
    }

    @Test
    fun doubleTrailingLfKeyFrameStaysRefused() {
        // Exactly ONE terminator is protocol content; a second is embedded.
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            editable("key type=input char=13 key=1280\n\n").decision,
        )
    }

    @Test
    fun nulByteKeyFrameStaysRefused() {
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            editable("key type=input char=0 key=1280\u0000\n").decision,
        )
    }

    @Test
    fun trailingLfIsAcceptedOnNoOtherCommand() {
        // No other pinned frame terminates with LF, so all other commands
        // keep the strict framing guard AND their own refusal semantics.
        val saveFrame = editable("save dontTerminateEdit=1 dontSaveIfUnmodified=0\n")
        assertEquals(CoolMessageGate.Decision.BLOCK_ROUTE, saveFrame.decision)
        assertEquals("editModeBlocked", saveFrame.noticeKey)
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            editable("uno .uno:Save\n").decision,
        )
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            readOnly("downloadas name=\"x.pdf\"\n").decision,
        )
    }

    @Test
    fun oversizedKeyFrameStaysRefused() {
        val huge = "key type=input char=0 key=1280 " + "a".repeat(70000) + "\n"
        assertEquals(CoolMessageGate.Decision.BLOCK_ROUTE, editable(huge).decision)
    }

    @Test
    fun unknownCommandWithLfKeepsPreviewRefusal() {
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            readOnly("someunknowncmd\n").decision,
        )
        // permissionmode is refused in BOTH modes regardless of framing.
        assertEquals(
            CoolMessageGate.Decision.BLOCK_ROUTE,
            editable("permissionmode edit\n").decision,
        )
    }
}
