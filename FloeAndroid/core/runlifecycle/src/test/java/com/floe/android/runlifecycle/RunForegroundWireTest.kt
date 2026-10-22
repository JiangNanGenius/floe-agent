// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Interop pin (Main review): the parser MUST accept the EXACT line the
 * Swift RunForegroundProjection.serialize emits (`1`/`0` booleans) and
 * MUST report drift (e.g. "true"/"false") as unknown instead of silently
 * marking every real readback unknown OR — worse — inventing truth.
 */
class RunForegroundWireTest {

    private fun swiftSerialized(
        epoch: Long, storeReady: Boolean, fenced: Boolean,
        run: Int, childRun: Int, tool: Int, conversation: Int, vault: Int,
    ): String =
        "epoch=$epoch;storeReady=${if (storeReady) 1 else 0};admissionFenced=${if (fenced) 1 else 0};" +
            "run=$run;childRun=$childRun;tool=$tool;conversation=$conversation;vaultMaintenance=$vault"

    @Test
    fun actualSerializedLineParsesToExactTruth() {
        val line = swiftSerialized(
            epoch = 7, storeReady = true, fenced = false,
            run = 1, childRun = 0, tool = 2, conversation = 0, vault = 1,
        )
        val work = RunForegroundWire.parse(line)
        requireNotNull(work) { "the real wire format must parse" }
        assertEquals(7L, work.nativeRootEpoch)
        assertTrue(work.storeReady)
        assertFalse(work.admissionFenced)
        assertEquals(1, work.runCount)
        assertEquals(0, work.childRunCount)
        assertEquals(2, work.toolCount)
        assertEquals(0, work.conversationCount)
        assertEquals(1, work.vaultMaintenanceCount)
        assertTrue(work.hasLiveRunOwnedWork)
    }

    @Test
    fun zeroAgentWorkIsKnownAndSettleable() {
        val line = swiftSerialized(7, true, false, 0, 0, 0, 0, 0)
        val work = RunForegroundWire.parse(line)
        requireNotNull(work)
        assertFalse("known ledger truth with no runs or tools", work.hasLiveRunOwnedWork)
    }

    @Test
    fun ownedToolCleanupAloneKeepsAgentWorkLive() {
        // Main rule: a root run ended while its owned tool cleanup is
        // still attached must NOT be read as quiescent (Core would freeze
        // mid cleanup otherwise).
        val line = swiftSerialized(7, true, false, 0, 0, 1, 0, 0)
        val work = RunForegroundWire.parse(line)
        requireNotNull(work)
        assertTrue(work.hasLiveRunOwnedWork)
        // Conversation/vault ledgers settle through their own owners.
        val vaultOnly = swiftSerialized(7, true, false, 0, 0, 0, 1, 2)
        val vaultWork = RunForegroundWire.parse(vaultOnly)
        requireNotNull(vaultWork)
        assertFalse(vaultWork.hasLiveRunOwnedWork)
    }

    @Test
    fun driftOrMalformationIsUnknownNeverTruth() {
        // "true"/"false" drift == whole line unknown (the exact interop
        // bug from review in the OTHER direction: never silent mis-parse).
        assertNull(RunForegroundWire.parse(
            "epoch=7;storeReady=true;admissionFenced=false;run=0;childRun=0;tool=0;conversation=0;vaultMaintenance=0"))
        assertNull(RunForegroundWire.parse(null))
        assertNull(RunForegroundWire.parse(""))
        assertNull(RunForegroundWire.parse("epoch=7;storeReady=1")) // partial
        assertNull(RunForegroundWire.parse("epoch=;storeReady=1;admissionFenced=0;run=0;childRun=0;tool=0;conversation=0;vaultMaintenance=0"))
        assertNull(RunForegroundWire.parse("epoch=-1;storeReady=1;admissionFenced=0;run=0;childRun=0;tool=0;conversation=0;vaultMaintenance=0"))
        assertNull(RunForegroundWire.parse("epoch=7;storeReady=1;admissionFenced=0;run=0;childRun=0;tool=0;conversation=0")) // missing vault
        assertNull(RunForegroundWire.parse("garbage"))
    }
}
