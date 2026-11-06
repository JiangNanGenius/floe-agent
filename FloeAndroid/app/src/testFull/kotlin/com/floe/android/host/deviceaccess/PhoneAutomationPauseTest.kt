// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class PhoneAutomationPauseTest {
    private val owner = PhoneControlOwner(UUID.randomUUID(), UUID.randomUUID())

    @Test fun savedPauseRestoresDenialForOnlyTheExactRun() {
        val gate = PhoneAutomationPause()
        val paused = gate.pause(owner, 100)
        val restored = PhoneAutomationPause(PhoneAutomationPause.Snapshot.decode(paused.encode()))
        assertTrue(restored.isPaused(owner))
        assertFalse(restored.isPaused(owner.copy(runID = UUID.randomUUID())))
        assertEquals(paused, restored.snapshot)
        assertNull(PhoneAutomationPause.Snapshot.decode("1|1-1-1-1-1|invalid|100|invalid"))
        assertNull(PhoneAutomationPause.Snapshot.decode(paused.encode().replace("|100|", "|0|")))
    }

    @Test fun oldNotificationAndForeignOwnerCannotResumeNewPause() {
        val gate = PhoneAutomationPause()
        val old = gate.pause(owner, 100)
        val fresh = gate.pause(owner, 200)
        assertFalse(gate.resume(owner, old.id))
        assertFalse(gate.resume(owner.copy(taskID = UUID.randomUUID()), fresh.id))
        assertTrue(gate.isPaused(owner))
        assertTrue(gate.resume(owner, fresh.id))
        assertFalse(gate.isPaused(owner))
        assertFalse(gate.resume(owner, fresh.id))
    }

    @Test fun humanApprovalNeedsTheCurrentPauseAndMustPostdateIt() {
        val gate = PhoneAutomationPause()
        val old = gate.pause(owner, 100)
        val paused = gate.pause(owner, 200)
        assertFalse(gate.resumeAfterHumanAnswer(owner, null, 300))
        assertFalse(gate.resumeAfterHumanAnswer(owner, old.id, 300))
        assertFalse(gate.resumeAfterHumanAnswer(owner, paused.id, 200))
        assertFalse(gate.resumeAfterHumanAnswer(owner.copy(runID = UUID.randomUUID()), paused.id, 300))
        assertTrue(gate.resumeAfterHumanAnswer(owner, paused.id, 300))
    }

    @Test fun failedPersistenceNeverLiftsTheDenialFence() {
        val gate = PhoneAutomationPause()
        val paused = gate.pause(owner, 100)
        assertFalse(gate.resume(owner, paused.id) { false })
        assertFalse(gate.resumeAfterHumanAnswer(owner, paused.id, 200) { false })
        assertTrue(gate.isPaused(owner))
    }

    @Test fun onlyRealOwnerCallBindingsSurviveProcessRestore() {
        val gate = PhoneAutomationPause()
        val pause = gate.pause(owner, 100)
        assertFalse(gate.bindQuestion(owner.copy(runID = UUID.randomUUID()), pause.id, "foreign") { true })
        assertFalse(gate.bindQuestion(owner, pause.id, "not-saved") { false })
        assertTrue(gate.bindQuestion(owner, pause.id, "call-1") { true })
        val restored = checkNotNull(PhoneAutomationPause.Snapshot.decode(checkNotNull(gate.snapshot).encode()))
        assertEquals(setOf("call-1"), restored.toolCallIDs)
        assertEquals(pause, PhoneAutomationPause.Snapshot.decode(pause.encode().substringBeforeLast('|')))
    }
}
