// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G03-R3 authored-not-run control-plane test: the two workspace preflight
 * operations are dedicated AUTHENTICATED host controls, and their addition
 * must never alter the pre-existing shell-facing operation set (which is
 * what model-driven shell work uses). Wire (de)code itself needs the
 * Android JSON stack and stays in Main's instrumented/device lane.
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
        // Nothing else may be smuggled in. The one extra member tolerated is
        // the CLEANUP lane's frozen host control (merge-stable union); any
        // other new operation fails this gate.
        val known = legacy + setOf(RuntimeWire.PREFLIGHT, RuntimeWire.PREFLIGHT_CANCEL,
            "runtimeWorkspaceCopies.clear")
        assertTrue(RuntimeWire.operations.all { it in known })
    }

    @Test fun aPreflightIsNotAShellStart() {
        // The whole point of the dedicated control: it can never be reached
        // through, or renamed to, any shell-facing operation.
        assertFalse(RuntimeWire.PREFLIGHT.startsWith("shell."))
        assertFalse(RuntimeWire.PREFLIGHT_CANCEL.startsWith("shell."))
    }
}
