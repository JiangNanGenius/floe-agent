// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Control-plane contract: the two workspace preflight
 * operations are dedicated AUTHENTICATED host controls, and their addition
 * must never alter the pre-existing shell-facing operation set (which is
 * what model-driven shell work uses). The App's LinuxShellInputSyncWireTest
 * separately exercises production wire (de)code and receiver admission.
 */
class RuntimeWirePreflightOperationsTest {

    @Test fun preflightControlsAreAllowlistedExactly() {
        assertEquals("workspace.preflight", RuntimeWire.PREFLIGHT)
        assertEquals("workspace.preflight.cancel", RuntimeWire.PREFLIGHT_CANCEL)
        assertTrue(RuntimeWire.PREFLIGHT in RuntimeWire.operations)
        assertTrue(RuntimeWire.PREFLIGHT_CANCEL in RuntimeWire.operations)
    }

    @Test fun legacyOperationSetIsUntouchedByThePreflightControls() {
        val legacy = setOf("status", "request.status", "install.start", "install.cancel",
            "install.status", "environment.list", "shell.start", "shell.poll", "shell.input",
            "shell.resize", "shell.cancel")
        assertTrue(legacy.all { it in RuntimeWire.operations })
        // Include the subsequently shipped typed controls explicitly and
        // freeze the entire set, rather than accepting arbitrary new tokens.
        val known = legacy + setOf(RuntimeWire.PREFLIGHT, RuntimeWire.PREFLIGHT_CANCEL,
            "runtimeWorkspaceCopies.clear", "stdio.start", "stdio.write", "stdio.poll",
            "stdio.stdinEof", "service.readiness", "workspace.files.tree",
            "workspace.files.read", "workspace.exportStatus", "storage.inventory",
            "storage.cleanup", "workspace.syncInputs")
        assertEquals(known, RuntimeWire.operations)
    }

    @Test fun aPreflightIsNotAShellStart() {
        // The whole point of the dedicated control: it can never be reached
        // through, or renamed to, any shell-facing operation.
        assertFalse(RuntimeWire.PREFLIGHT.startsWith("shell."))
        assertFalse(RuntimeWire.PREFLIGHT_CANCEL.startsWith("shell."))
    }

    @Test fun hotInputSyncIsANonExecutingAllowlistedControl() {
        assertEquals("workspace.syncInputs", RuntimeWire.SYNC_INPUTS)
        assertTrue(RuntimeWire.SYNC_INPUTS in RuntimeWire.operations)
        assertFalse(RuntimeWire.SYNC_INPUTS.startsWith("shell."))
        assertFalse(RuntimeWire.SYNC_INPUTS.startsWith("stdio."))
    }
}
