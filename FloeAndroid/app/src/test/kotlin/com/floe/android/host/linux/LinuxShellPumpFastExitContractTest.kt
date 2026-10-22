// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Receipt routing must follow the operation, not overlapping process states. */
class LinuxShellPumpFastExitContractTest {
    @Test fun livePollReturnsItsImmediateSnapshot() {
        assertFalse(LinuxShellPump.requiresControlReceipt("shell.poll"))
    }

    @Test fun mutatingControlsStillAwaitTheirReceipts() {
        assertTrue(LinuxShellPump.requiresControlReceipt("shell.input"))
        assertTrue(LinuxShellPump.requiresControlReceipt("shell.resize"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun unknownOperationCannotUseTheSnapshotShortcut() {
        LinuxShellPump.requiresControlReceipt("shell.start")
    }

    @Test fun onlyEmptyInputMayUseTheTerminalEofAcknowledgement() {
        assertTrue(LinuxShellPump.isEofInputPage(""))
        assertFalse(LinuxShellPump.isEofInputPage("aGk="))
        assertFalse(LinuxShellPump.isEofInputPage("AAAA"))
    }
}
