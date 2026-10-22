// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceRelativeValidationTest {
    @Test
    fun ordinaryRelativePathsPass() {
        assertNotNull(WorkspaceRelativeValidation.validate("a.txt"))
        assertNotNull(WorkspaceRelativeValidation.validate("src/main/kotlin/App.kt"))
        assertNotNull(WorkspaceRelativeValidation.validate("node_modules/.bin/tsc"))
    }

    @Test
    fun traversalAndShapeAttacksRefused() {
        assertNull(WorkspaceRelativeValidation.validate("/absolute/path"))
        assertNull(WorkspaceRelativeValidation.validate("~/outside"))
        assertNull(WorkspaceRelativeValidation.validate("a/../../etc/passwd"))
        assertNull(WorkspaceRelativeValidation.validate("a/./b"))
        assertNull(WorkspaceRelativeValidation.validate("a//b"))
        assertNull(WorkspaceRelativeValidation.validate(""))
        assertNull(WorkspaceRelativeValidation.validate("a\u0000b"))
        assertNull(WorkspaceRelativeValidation.validate("line\nbreak"))
        assertNull(WorkspaceRelativeValidation.validate("a/" + "x".repeat(300)))
        assertNull(WorkspaceRelativeValidation.validate((1..300).joinToString("/") { "d" }))
    }

    @Test
    fun reservedTransferPrefixesRefused() {
        assertNull(WorkspaceRelativeValidation.validate(".floe-commit-abc"))
        assertNull(WorkspaceRelativeValidation.validate(".floe-wt-anything/x"))
        assertNull(WorkspaceRelativeValidation.validate(".workspace-bridge/x"))
    }

    @Test
    fun linkTargetClassificationKeepsContainedAndRefusesEscape() {
        val budgets = 2048
        assertTrue(WorkspaceRelativeValidation.linkTargetContained(
            "../../pkg/.bin/tsc", listOf("node_modules", ".bin", "tsc"), budgets))
        assertTrue(WorkspaceRelativeValidation.linkTargetContained("b.txt", listOf("a", "x"), budgets))
        assertFalse(WorkspaceRelativeValidation.linkTargetContained("/etc/passwd", listOf("x"), budgets))
        assertFalse(WorkspaceRelativeValidation.linkTargetContained("../../outside", listOf("only", "one"), budgets))
        assertFalse(WorkspaceRelativeValidation.linkTargetContained("", listOf("x"), budgets))
        assertFalse(WorkspaceRelativeValidation.linkTargetContained("a\u0000b", listOf("x"), budgets))
    }

    @Test
    fun budgetSanitizeRefusesWideningAndBooleans() {
        val good = org.json.JSONObject()
            .put("totalBytes", 1024L * 1024L * 1024L)
            .put("entryCount", 10000)
            .put("frameBytes", 65536)
            .put("maximumEntryBytes", 1024L * 1024L * 1024L)
            .put("freeDiskReserveBytes", 512L * 1024L * 1024L)
            .put("maximumRelativePathBytes", 2048)
            .put("maximumLinkTargetBytes", 2048)
        assertNotNull(WorkspaceBudgetsView.sanitize(good))
        val widened = org.json.JSONObject(good.toString())
            .put("totalBytes", (1L shl 40))
        assertNull(WorkspaceBudgetsView.sanitize(widened))
        val booleanEntry = org.json.JSONObject(good.toString()).put("entryCount", true)
        assertNull(WorkspaceBudgetsView.sanitize(booleanEntry))
        val fractional = org.json.JSONObject(good.toString()).put("frameBytes", 4096.5)
        // JSON 4096.5: not integral => refused.
        assertNull(WorkspaceBudgetsView.sanitize(fractional))
    }

    @Test
    fun maxBytesConstantsMatchDocumentedOctal() {
        assertEquals(493, WorkspaceFileModes.DIR_DEFAULT) // 0755
        assertEquals(420, WorkspaceFileModes.FILE_DEFAULT) // 0644
        assertEquals(4095, WorkspaceFileModes.ALL_BITS) // 07777
    }
}

class WorkspaceIOLatchTest {
    @Test
    fun fenceRefusesNewEntriesAndDrainWaitsForEntered() {
        val latch = WorkspaceIOLatch()
        assertTrue(latch.begin())
        assertTrue(latch.begin())
        assertEquals(2, latch.inflightCount)
        val released = java.util.concurrent.atomic.AtomicBoolean(false)
        val waiter = Thread {
            latch.fence()
            latch.awaitDrained()
            released.set(true)
        }
        waiter.start()
        Thread.sleep(80)
        // Both entered transactions are still running: the drain MUST NOT
        // have returned (no timeout release).
        assertFalse(released.get())
        latch.end()
        Thread.sleep(80)
        assertFalse("one transaction outstanding still blocks the drain", released.get())
        latch.end()
        waiter.join(5_000)
        assertFalse(waiter.isAlive)
        assertTrue("drain completes only after every entered transaction returned", released.get())
        assertFalse(latch.begin()) // fenced: no new entry
    }

    @Test
    fun endWithoutBeginRefusedAndSecondFenceIsHarmless() {
        val latch = WorkspaceIOLatch()
        assertTrue(latch.fence())
        assertFalse(latch.fence())
        assertFalse(latch.begin())
        latch.awaitDrained() // zero entered: returns immediately
    }
}
