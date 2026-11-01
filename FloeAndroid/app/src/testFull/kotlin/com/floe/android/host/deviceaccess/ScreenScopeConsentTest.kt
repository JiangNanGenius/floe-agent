// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the RAM-only screen-share consent. No Android,
// Compose, service, device or preference storage is constructed here.
package com.floe.android.host.deviceaccess

import com.floe.android.DeviceAccessScreenScopeUi
import com.floe.android.phonecontrol.PhoneControlBlocker
import com.floe.android.phonecontrol.PhoneControlOwner
import com.floe.android.phonecontrol.PhoneControlScreenshotSupport
import com.floe.android.phonecontrol.PhoneControlStatus
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the real candidate04 inheritance failure and the completion gate:
 *  - "This task" is valid only for the exact live owner + epoch selected;
 *  - a different live task, a terminal run, a process reconstruction and an
 *    epoch change never inherit it;
 *  - "Until stopped" is the distinct broader mode: it survives a task
 *    terminal but still ends at Stop/Takeover, epoch change or teardown;
 *  - a pending asynchronous capture is rejected after the consent was
 *    revoked or revoked+regranted, and after whole-screen consent was
 *    removed for an original display capture.
 */
class ScreenScopeConsentTest {

    private val epoch = 7L
    private val a = owner(1, 11)
    private val b = owner(2, 22)

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    private fun ScreenScopeConsent.thisTask(owner: PhoneControlOwner): ScreenScopeSelection =
        select(
            requested = DeviceAccessScreenScopeUi.CURRENT_TASK,
            candidateOwner = owner,
            sessionOwner = owner,
            epoch = epoch,
        )

    private fun ScreenScopeConsent.untilStopped(owner: PhoneControlOwner): ScreenScopeSelection =
        select(
            requested = DeviceAccessScreenScopeUi.UNTIL_STOPPED,
            candidateOwner = owner,
            sessionOwner = owner,
            epoch = epoch,
        )

    // -------------------------------------------------------- exact task mode

    @Test
    fun thisTaskIsBoundToTheExactLiveOwnerAndEpoch() {
        val consent = ScreenScopeConsent()
        val selection = consent.thisTask(a)

        assertTrue(selection is ScreenScopeSelection.Active)
        assertEquals(DeviceAccessScreenScopeUi.CURRENT_TASK, consent.binding?.mode)
        assertEquals(a, consent.binding?.owner)
        assertEquals(epoch, consent.binding?.epoch ?: -1L)

        assertTrue("same live owner is covered", consent.allows(a, epoch, ownerRunLive = true))
        assertFalse("same owner after its run terminated", consent.allows(
            a, epoch, ownerRunLive = false))
        assertFalse("another live task never inherits", consent.allows(
            b, epoch, ownerRunLive = true))
        assertFalse("a new epoch revokes", consent.allows(a, epoch + 1, ownerRunLive = true))
    }

    @Test
    fun differentLiveTaskDoesNotPresentThisTask() {
        val consent = ScreenScopeConsent()
        consent.thisTask(a)

        assertEquals(
            DeviceAccessScreenScopeUi.CURRENT_TASK,
            consent.presented(activeOwner = a, liveCandidateOwner = a, epoch = epoch),
        )
        assertEquals(
            "the stale A choice is not highlighted on live B",
            DeviceAccessScreenScopeUi.OFF,
            consent.presented(activeOwner = b, liveCandidateOwner = b, epoch = epoch),
        )
        assertEquals(
            "a retained/terminal row is not a live candidate",
            DeviceAccessScreenScopeUi.OFF,
            consent.presented(activeOwner = a, liveCandidateOwner = null, epoch = epoch),
        )
    }

    @Test
    fun thisTaskTerminalReconciliationDropsTheConsent() {
        val consent = ScreenScopeConsent()
        consent.thisTask(a)

        consent.reconcile(epoch) { false }

        assertNull(consent.binding)
        assertFalse(consent.allows(a, epoch, ownerRunLive = true))
        assertEquals(
            DeviceAccessScreenScopeUi.OFF,
            consent.presented(activeOwner = a, liveCandidateOwner = a, epoch = epoch),
        )
    }

    @Test
    fun noLiveCandidateCannotMintThisTask() {
        val consent = ScreenScopeConsent()
        val refused = consent.select(
            requested = DeviceAccessScreenScopeUi.CURRENT_TASK,
            candidateOwner = null,
            sessionOwner = a,
            epoch = epoch,
        )

        assertTrue(refused is ScreenScopeSelection.Refused)
        assertEquals(
            ScreenScopeConsent.CODE_NO_LIVE_TASK,
            (refused as ScreenScopeSelection.Refused).code,
        )
        assertNull(consent.binding)
        assertFalse(consent.allows(a, epoch, ownerRunLive = true))
    }

    @Test
    fun selectionRequiresAValidNativeEpoch() {
        val consent = ScreenScopeConsent()

        val thisTask = consent.select(
            DeviceAccessScreenScopeUi.CURRENT_TASK, a, a, epoch = null)
        val untilStopped = consent.select(
            DeviceAccessScreenScopeUi.UNTIL_STOPPED, a, a, epoch = 0L)

        assertEquals(
            ScreenScopeConsent.CODE_RUNTIME_NOT_READY,
            (thisTask as ScreenScopeSelection.Refused).code,
        )
        assertEquals(
            ScreenScopeConsent.CODE_RUNTIME_NOT_READY,
            (untilStopped as ScreenScopeSelection.Refused).code,
        )
        assertNull(consent.binding)
    }

    // ------------------------------------------------------- broader mode

    @Test
    fun untilStoppedIsBroaderButStillEpochBound() {
        val consent = ScreenScopeConsent()
        val selection = consent.untilStopped(a)

        assertTrue(selection is ScreenScopeSelection.Active)
        assertEquals(DeviceAccessScreenScopeUi.UNTIL_STOPPED, consent.binding?.mode)
        assertNull(consent.binding?.owner)
        assertTrue(consent.allows(a, epoch, ownerRunLive = true))
        assertTrue("explicitly broader across live tasks", consent.allows(
            b, epoch, ownerRunLive = true))
        assertFalse("dead A cannot use the broader mode either", consent.allows(
            a, epoch, ownerRunLive = false))
        assertFalse("a non-live owner never screenshots", consent.allows(
            b, epoch, ownerRunLive = false))
        assertFalse("still bound to the native epoch", consent.allows(
            a, epoch + 1, ownerRunLive = true))
        assertEquals(
            DeviceAccessScreenScopeUi.UNTIL_STOPPED,
            consent.presented(activeOwner = b, liveCandidateOwner = b, epoch = epoch),
        )
        assertEquals(
            "no task displayed means no scope row",
            DeviceAccessScreenScopeUi.OFF,
            consent.presented(activeOwner = null, liveCandidateOwner = null, epoch = epoch),
        )
    }

    @Test
    fun untilStoppedSurvivesTaskTerminalButNotAnActualStop() {
        val consent = ScreenScopeConsent()
        consent.untilStopped(a)

        consent.reconcile(epoch) { false }
        assertNotNull("the broader mode does not end with task A", consent.binding)
        assertFalse("dead A cannot dispatch a screenshot", consent.allows(
            a, epoch, ownerRunLive = false))
        assertNull("dead A cannot mint a capture ticket", consent.ticket(
            a, epoch, ownerRunLive = false))
        assertTrue("the next live B after an explicit arm is covered",
            consent.allows(b, epoch, ownerRunLive = true))
        assertNotNull("live B gets a capture ticket", consent.ticket(
            b, epoch, ownerRunLive = true))
        assertEquals(
            DeviceAccessScreenScopeUi.UNTIL_STOPPED,
            consent.presented(activeOwner = b, liveCandidateOwner = b, epoch = epoch),
        )

        consent.clear()
        assertNull(consent.binding)
        assertFalse(consent.allows(b, epoch, ownerRunLive = true))
        assertEquals(
            DeviceAccessScreenScopeUi.OFF,
            consent.presented(activeOwner = b, liveCandidateOwner = b, epoch = epoch),
        )
    }

    @Test
    fun movingTheGrantEndsOnlyTheOldOwnersExactTaskConsent() {
        val consent = ScreenScopeConsent()
        consent.untilStopped(a)
        consent.clearExactTask(a)
        assertNotNull("Until stopped survives the task switch", consent.binding)

        // The user chose This task for the NEW task before arming it while
        // the service still held the old owner. Ending the old owner must not
        // clear the new task's explicit choice.
        consent.thisTask(b)
        consent.clearExactTask(a)
        assertEquals(b, consent.binding?.owner)
        assertTrue(consent.allows(b, epoch, ownerRunLive = true))

        consent.clearExactTask(b)
        assertNull("This task does not survive its own owner leaving", consent.binding)
    }

    @Test
    fun refusedThisTaskDoesNotNarrowAnExistingBroaderMode() {
        val consent = ScreenScopeConsent()
        consent.untilStopped(a)

        val refused = consent.select(
            requested = DeviceAccessScreenScopeUi.CURRENT_TASK,
            candidateOwner = null,
            sessionOwner = a,
            epoch = epoch,
        )
        assertTrue(refused is ScreenScopeSelection.Refused)
        assertEquals(DeviceAccessScreenScopeUi.UNTIL_STOPPED, consent.binding?.mode)
        assertTrue(consent.allows(b, epoch, ownerRunLive = true))
    }

    // -------------------------------------------------- lifecycle revocation

    @Test
    fun epochChangeRevokesBothModes() {
        val thisTask = ScreenScopeConsent()
        thisTask.thisTask(a)
        thisTask.reconcile(epoch + 1) { true }
        assertNull(thisTask.binding)
        assertFalse(thisTask.allows(a, epoch + 1, ownerRunLive = true))

        val untilStopped = ScreenScopeConsent()
        untilStopped.untilStopped(a)
        untilStopped.reconcile(epoch + 1) { true }
        assertNull(untilStopped.binding)
        assertFalse(untilStopped.allows(a, epoch + 1, ownerRunLive = true))
    }

    @Test
    fun processReconstructionStartsWithNoScreenConsent() {
        // A fresh host/process constructs a fresh state object. Preference
        // storage is deliberately not consulted anywhere in this helper.
        val reconstructed = ScreenScopeConsent()

        assertNull(reconstructed.binding)
        assertNull(reconstructed.ticket(a, epoch, ownerRunLive = true))
        assertFalse(reconstructed.allows(a, epoch, ownerRunLive = true))
        assertEquals(
            DeviceAccessScreenScopeUi.OFF,
            reconstructed.presented(activeOwner = a, liveCandidateOwner = a, epoch = epoch),
        )
    }

    @Test
    fun serviceStopArmBlockersAreNotAServiceTeardown() {
        val connected = PhoneControlStatus(
            connected = true,
            enabled = true,
            blocker = null,
            activeOwner = a,
            fenceGeneration = 1,
            pageGeneration = 1,
            screenshotSupport = PhoneControlScreenshotSupport.DISPLAY,
        )
        assertFalse("connected service is not torn down", phoneServiceTornDown(connected))
        assertFalse(
            "the explicit Stop/arm transition is not a teardown",
            phoneServiceTornDown(connected.copy(blocker = PhoneControlBlocker.STOPPED)),
        )
        assertFalse(
            "a takeover while arming the next task is not a teardown",
            phoneServiceTornDown(connected.copy(blocker = PhoneControlBlocker.TAKEN_OVER)),
        )
        assertFalse(
            "a user touch is not a teardown",
            phoneServiceTornDown(connected.copy(blocker = PhoneControlBlocker.USER_TOUCH)),
        )
        assertTrue(
            "accessibility revoked is a teardown",
            phoneServiceTornDown(connected.copy(blocker = PhoneControlBlocker.SERVICE_REVOKED)),
        )
        assertTrue(
            "driver disconnected is a teardown",
            phoneServiceTornDown(connected.copy(blocker = PhoneControlBlocker.SERVICE_DISCONNECTED)),
        )
        assertTrue(
            "disconnected service is a teardown",
            phoneServiceTornDown(connected.copy(connected = false)),
        )
        assertTrue(
            "disabled service is a teardown",
            phoneServiceTornDown(connected.copy(enabled = false)),
        )
    }

    // ------------------------------------------------- completion ticket

    @Test
    fun pendingCaptureIsRejectedAfterScopeRevocation() {
        val consent = ScreenScopeConsent()
        consent.thisTask(a)
        val ticket = consent.ticket(a, epoch, ownerRunLive = true)
        assertNotNull(ticket)

        consent.clear()

        assertFalse(consent.ticketStillValid(
            ticket, a, epoch, ownerRunLive = true,
            displayCapture = false, wholeScreenConsent = false,
        ))
        assertNull(consent.ticket(a, epoch, ownerRunLive = true))
    }

    @Test
    fun pendingCaptureIsRejectedAfterRevokeAndRegrant() {
        val consent = ScreenScopeConsent()
        consent.thisTask(a)
        val pending = consent.ticket(a, epoch, ownerRunLive = true)
        assertNotNull(pending)

        // The user revokes and re-grants the SAME mode/owner/epoch while the
        // async capture is still pending. The old ticket is not the new grant.
        consent.clear()
        consent.thisTask(a)

        assertFalse(consent.ticketStillValid(
            pending, a, epoch, ownerRunLive = true,
            displayCapture = false, wholeScreenConsent = false,
        ))
        val fresh = consent.ticket(a, epoch, ownerRunLive = true)
        assertNotNull(fresh)
        assertNotEquals(pending?.revision, fresh?.revision)
        assertTrue(consent.ticketStillValid(
            fresh, a, epoch, ownerRunLive = true,
            displayCapture = false, wholeScreenConsent = false,
        ))
    }

    @Test
    fun pendingCaptureIsBoundToItsExactOwner() {
        val consent = ScreenScopeConsent()
        consent.untilStopped(a)
        val ticket = consent.ticket(a, epoch, ownerRunLive = true)
        assertNotNull(ticket)

        assertFalse("a different owner cannot reuse the ticket", consent.ticketStillValid(
            ticket, b, epoch, ownerRunLive = true,
            displayCapture = false, wholeScreenConsent = true,
        ))
        assertFalse("a different epoch cannot reuse the ticket", consent.ticketStillValid(
            ticket, a, epoch + 1, ownerRunLive = true,
            displayCapture = false, wholeScreenConsent = true,
        ))
    }

    @Test
    fun pendingDisplayCaptureRequiresCurrentWholeScreenConsent() {
        val consent = ScreenScopeConsent()
        consent.thisTask(a)
        val ticket = consent.ticket(a, epoch, ownerRunLive = true)
        assertNotNull(ticket)

        assertTrue("original display consent was current", consent.ticketStillValid(
            ticket, a, epoch, ownerRunLive = true,
            displayCapture = true, wholeScreenConsent = true,
        ))
        assertFalse("whole-screen consent removed while capture pending", consent.ticketStillValid(
            ticket, a, epoch, ownerRunLive = true,
            displayCapture = true, wholeScreenConsent = false,
        ))
        assertFalse("revoked and re-granted consent is a new grant", consent.ticketStillValid(
            ticket, a, epoch, ownerRunLive = true,
            displayCapture = true, wholeScreenConsent = true,
            wholeScreenUnchanged = false,
        ))
        assertTrue("an original window capture never needed it", consent.ticketStillValid(
            ticket, a, epoch, ownerRunLive = true,
            displayCapture = false, wholeScreenConsent = false,
        ))
    }

    @Test
    fun pendingThisTaskCaptureIsRejectedAfterTheRunTerminates() {
        val consent = ScreenScopeConsent()
        consent.thisTask(a)
        val ticket = consent.ticket(a, epoch, ownerRunLive = true)
        assertNotNull(ticket)

        assertFalse("terminal owner cannot complete a pending capture",
            consent.ticketStillValid(
                ticket, a, epoch, ownerRunLive = false,
                displayCapture = false, wholeScreenConsent = true,
            ))
    }
}
