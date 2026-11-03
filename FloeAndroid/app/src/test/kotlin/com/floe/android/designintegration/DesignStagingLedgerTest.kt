// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.host.creative.CreativeAcceptedRoot
import com.floe.android.host.creative.CreativeDesignStagingLedger
import java.io.ByteArrayInputStream
import java.io.File
import kotlinx.coroutines.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Adapted from designclosure30 `STAGING_TESTS.kt.txt` to the ACTUAL current
 * `CreativeDesignStagingLedger` API (NOT RUN in this source-only stage).
 *
 * It exercises only the pure staging state machine used by the real design
 * host: bounded slots reserved before IO, generation fencing, late-publication
 * refusal, exact accepted epoch/root proof, real worker return and cancel.
 */
class DesignStagingLedgerTest {
    private val root = CreativeAcceptedRoot(path = "/accepted/root", epoch = 7L)
    private fun target(token: String) = File("/accepted/root/FloeAgent/CreativeIncoming/$token")

    @Test
    fun slotIsReservedBeforeIoAndBoundedAcrossActiveAndStaged() {
        val ledger = CreativeDesignStagingLedger(2)
        assertNotNull(ledger.begin("a", root, target("a"), stagedCount = 0))
        assertNotNull(ledger.begin("b", root, target("b"), stagedCount = 0))
        assertNull(ledger.begin("c", root, target("c"), stagedCount = 0))
        assertEquals(2, ledger.activeCount())

        val other = CreativeDesignStagingLedger(2)
        assertNull(other.begin("d", root, target("d"), stagedCount = 2))
    }

    @Test
    fun fenceInvalidatesTheGenerationAndASecondStartCannotAttach() {
        val ledger = CreativeDesignStagingLedger(4)
        val generation = ledger.begin("a", root, target("a"), stagedCount = 0)!!
        val slots = ledger.fence()
        assertEquals(1, slots.size)
        assertFalse(ledger.attach("a", Job(), ByteArrayInputStream(ByteArray(1))))
        assertTrue(ledger.isCancelled("a", generation))
        assertFalse(ledger.canPublish("a", generation, 7L, root.path))
    }

    @Test
    fun cancelBlocksLatePublicationAndLeavesNoActiveCopy() {
        val ledger = CreativeDesignStagingLedger(4)
        val generation = ledger.begin("a", root, target("a"), stagedCount = 0)!!
        assertTrue(ledger.attach("a", Job(), ByteArrayInputStream(ByteArray(1))))
        val cancelled = ledger.cancel("a")
        assertNotNull(cancelled)
        assertEquals(0, ledger.activeCount())
        assertFalse(ledger.canPublish("a", generation, 7L, root.path))
        assertTrue(ledger.isCancelled("a", generation))
    }

    @Test
    fun publicationRequiresExactAcceptedEpochAndRoot() {
        val ledger = CreativeDesignStagingLedger(4)
        val generation = ledger.begin("a", root, target("a"), stagedCount = 0)!!
        assertTrue(ledger.attach("a", null, ByteArrayInputStream(ByteArray(1))))
        assertFalse(ledger.canPublish("a", generation, 8L, root.path))
        assertFalse(ledger.canPublish("a", generation, 7L, "/other/root"))
        assertTrue(ledger.canPublish("a", generation, 7L, root.path))
        ledger.publish("a")
        assertEquals(0, ledger.activeCount())
        assertFalse(ledger.canPublish("a", generation, 7L, root.path))
    }

    @Test
    fun fenceReturnsTheRealWorkersAndFinishDrainsThem() {
        val ledger = CreativeDesignStagingLedger(4)
        val generation = ledger.begin("a", root, target("a"), stagedCount = 0)!!
        val job = Job()
        assertTrue(ledger.attach("a", job, ByteArrayInputStream(ByteArray(1))))
        val workers = ledger.fence()
        assertEquals(1, workers.size)
        assertEquals(job, workers.first().job)
        assertTrue(workers.first().cancelled)
        assertEquals(1, ledger.activeCount())
        ledger.finish("a")
        assertEquals(0, ledger.activeCount())
        assertFalse(ledger.canPublish("a", generation, 7L, root.path))
    }

    @Test
    fun unfenceAllowsANewGenerationAndStillRejectsTheOldOne() {
        val ledger = CreativeDesignStagingLedger(4)
        val oldGeneration = ledger.begin("old", root, target("old"), stagedCount = 0)!!
        ledger.fence()
        ledger.unfence()
        val newGeneration = ledger.begin("new", root, target("new"), stagedCount = 0)!!
        assertTrue(newGeneration > oldGeneration)
        assertFalse(ledger.canPublish("old", oldGeneration, 7L, root.path))
        assertTrue(ledger.canPublish("new", newGeneration, 7L, root.path))
    }
}
