// SPDX-License-Identifier: MPL-2.0
// Proposed JVM regression source — integrate into
// app/src/test/kotlin/com/floe/android/ and run in Main's batched JVM set.
// NOT executed in this private lane.
package com.floe.android

import com.floe.android.host.TerminalLanguageRuntimeState
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the honest readiness labels of the language-services settings row
 * (device cohort 2026-10-25): "unavailable"+"saturated" is the single-slot
 * busy refusal — the user must close the live terminal/run and retry, and
 * the UI must NOT call it "Stopped with an error". "toolMissing" stays
 * "Not installed"; every other unavailable code remains an honest failure.
 * The function only SELECTS copy from the typed native lifecycle answer.
 */
class WorkspaceLanguageStateLabelTest {

    @Test
    fun busySlotRefusalIsItsOwnHonestLabel() {
        assertEquals(R.string.workspace_language_state_busy,
            languageStateRes(true, TerminalLanguageRuntimeState("unavailable", "saturated")))
    }

    @Test
    fun missingBackendStaysMissing() {
        assertEquals(R.string.workspace_language_state_missing,
            languageStateRes(true, TerminalLanguageRuntimeState("unavailable", "toolMissing")))
    }

    @Test
    fun otherUnavailableCodesStayHonestFailures() {
        assertEquals(R.string.workspace_language_state_failed,
            languageStateRes(true, TerminalLanguageRuntimeState("unavailable", "engineUnqualified")))
        assertEquals(R.string.workspace_language_state_failed,
            languageStateRes(true, TerminalLanguageRuntimeState("unavailable", "retired")))
        assertEquals(R.string.workspace_language_state_failed,
            languageStateRes(true, TerminalLanguageRuntimeState("failed", null)))
    }

    @Test
    fun uncheckedUnsettledStartingReadyAndReleasedKeepTheirTruths() {
        assertEquals(R.string.workspace_language_state_disabled, languageStateRes(false, null))
        assertEquals(R.string.workspace_language_state_unknown, languageStateRes(true, null))
        assertEquals(R.string.workspace_language_state_ready,
            languageStateRes(true, TerminalLanguageRuntimeState("ready", null)))
        assertEquals(R.string.workspace_language_state_starting,
            languageStateRes(true, TerminalLanguageRuntimeState("starting", null)))
        assertEquals(R.string.workspace_language_state_released,
            languageStateRes(true, TerminalLanguageRuntimeState("stopped", null)))
    }
}
