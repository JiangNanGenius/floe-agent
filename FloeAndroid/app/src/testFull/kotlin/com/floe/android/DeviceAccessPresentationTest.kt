// SPDX-License-Identifier: MPL-2.0
// Proposed JVM regression source. Authored only in this private lane; Main
// runs it in the batched JVM set. No compile/run claim here.
package com.floe.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Truthfulness policy for the stateless G08 Phone settings page.
 *
 * These pin the boundaries that a menu-only stub would violate:
 *  - disabled / pair-required / paired / service-alive / restart / revoked
 *    stay distinct states, and service-alive never appears for any other;
 *  - busy work cannot leave conflicting actions enabled (except cancelling
 *    the pairing handshake it is waiting on);
 *  - pairing-code entry exists only for an open pairing session and is
 *    exactly six digits;
 *  - Root is default-off and switchable only after a real grant was found;
 *    ADB (shell) state never enables Root;
 *  - screen-content scope and Stop/Takeover require a live active task.
 */
class DeviceAccessPresentationTest {

    // -------------------------------------------------------------- ADB states

    @Test
    fun adbStatesKeepDistinctStatusCopy() {
        val statuses = listOf(
            DeviceAccessAdbUi.Off,
            DeviceAccessAdbUi.PairRequired(),
            DeviceAccessAdbUi.Pairing,
            DeviceAccessAdbUi.Paired(),
            DeviceAccessAdbUi.ServiceAlive(effectiveUid = 2000),
            DeviceAccessAdbUi.ServiceDied(),
            DeviceAccessAdbUi.RestartRequired,
            DeviceAccessAdbUi.Revoked,
            DeviceAccessAdbUi.Error("Local service unavailable", "serviceDied"),
        ).map { DeviceAccessPresentation.adbStatusRes(it) }
        assertEquals("each ADB state must render its own status", 9, statuses.toSet().size)
    }

    @Test
    fun serviceAliveIsTheOnlyStateThatReportsTheLiveUid() {
        assertEquals(2000, DeviceAccessPresentation.adbEffectiveUid(
            DeviceAccessAdbUi.ServiceAlive(effectiveUid = 2000)))
        assertNull(DeviceAccessPresentation.adbEffectiveUid(DeviceAccessAdbUi.Paired(effectiveUid = 2000)))
        assertNull(DeviceAccessPresentation.adbEffectiveUid(DeviceAccessAdbUi.RestartRequired))
        assertNull(DeviceAccessPresentation.adbEffectiveUid(DeviceAccessAdbUi.ServiceDied("died")))
        assertNull(DeviceAccessPresentation.adbEffectiveUid(DeviceAccessAdbUi.Off))
    }

    @Test
    fun adbActionSetsFollowTheActualState() {
        assertEquals(setOf(DeviceAccessAdbActionUi.ENABLE),
            DeviceAccessPresentation.adbActions(DeviceAccessAdbUi.Off))
        assertEquals(
            setOf(DeviceAccessAdbActionUi.PAIR, DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS),
            DeviceAccessPresentation.adbActions(DeviceAccessAdbUi.PairRequired()))
        assertEquals(
            setOf(
                DeviceAccessAdbActionUi.SUBMIT_CODE,
                DeviceAccessAdbActionUi.CANCEL_PAIRING,
                DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS,
            ),
            DeviceAccessPresentation.adbActions(DeviceAccessAdbUi.PairRequired(pairingSessionOpen = true)))
        assertEquals(setOf(DeviceAccessAdbActionUi.START, DeviceAccessAdbActionUi.FORGET),
            DeviceAccessPresentation.adbActions(DeviceAccessAdbUi.Paired()))
        assertEquals(setOf(DeviceAccessAdbActionUi.STOP, DeviceAccessAdbActionUi.FORGET),
            DeviceAccessPresentation.adbActions(DeviceAccessAdbUi.ServiceAlive(2000)))
        assertEquals(
            setOf(DeviceAccessAdbActionUi.START, DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS),
            DeviceAccessPresentation.adbActions(DeviceAccessAdbUi.RestartRequired))
        assertEquals(
            setOf(DeviceAccessAdbActionUi.PAIR, DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS),
            DeviceAccessPresentation.adbActions(DeviceAccessAdbUi.Revoked))
    }

    @Test
    fun busyWorkDisablesConflictingActionsButKeepsPairingCancel() {
        val busyStart = DeviceAccessPresentation.adbActions(
            DeviceAccessAdbUi.Paired(), DeviceAccessBusyUi.STARTING)
        assertTrue("nothing else may start while a start is in flight", busyStart.isEmpty())
        assertEquals(
            setOf(DeviceAccessAdbActionUi.CANCEL_PAIRING),
            DeviceAccessPresentation.adbActions(
                DeviceAccessAdbUi.PairRequired(pairingSessionOpen = true),
                DeviceAccessBusyUi.PAIRING,
            ),
        )
    }

    // ------------------------------------------------------------ pairing code

    @Test
    fun pairingCodeIsSixDigitsAndNeverSubmittableOtherwise() {
        assertEquals("123456", DeviceAccessPairingCode.sanitize("12 34-56 78"))
        assertEquals("123456", DeviceAccessPairingCode.sanitize("abcdef123456789"))
        assertTrue(DeviceAccessPairingCode.canSubmit("123456"))
        assertTrue(DeviceAccessPairingCode.canSubmit("1234567"))
        assertFalse(DeviceAccessPairingCode.canSubmit("12345"))
        assertFalse(DeviceAccessPairingCode.canSubmit(""))
        assertFalse(DeviceAccessPairingCode.canSubmit("12a456"))
    }

    @Test
    fun codeFieldAndSubmitExistOnlyForAnOpenPairingSession() {
        assertFalse(DeviceAccessPresentation.adbShowsCodeField(DeviceAccessAdbUi.PairRequired()))
        assertTrue(DeviceAccessPresentation.adbShowsCodeField(
            DeviceAccessAdbUi.PairRequired(pairingSessionOpen = true)))
        assertFalse(DeviceAccessPresentation.adbShowsCodeField(DeviceAccessAdbUi.Pairing))
        assertFalse(DeviceAccessPresentation.adbShowsCodeField(DeviceAccessAdbUi.ServiceAlive(2000)))

        assertTrue(DeviceAccessPresentation.adbSubmitEnabled(
            "123456", DeviceAccessAdbUi.PairRequired(pairingSessionOpen = true), DeviceAccessBusyUi.NONE))
        assertFalse("a busy handshake cannot submit twice", DeviceAccessPresentation.adbSubmitEnabled(
            "123456", DeviceAccessAdbUi.PairRequired(pairingSessionOpen = true), DeviceAccessBusyUi.PAIRING))
        assertFalse("five digits are not a pairing code", DeviceAccessPresentation.adbSubmitEnabled(
            "12345", DeviceAccessAdbUi.PairRequired(pairingSessionOpen = true), DeviceAccessBusyUi.NONE))
    }

    // ------------------------------------------------------------------- root

    @Test
    fun rootStartsOffAndCannotBeSwitchedWithoutAnActualGrant() {
        assertFalse(DeviceAccessPresentation.rootSwitchChecked(DeviceAccessRootUi.Off))
        assertFalse("default off", DeviceAccessPresentation.rootSwitchEnabled(DeviceAccessRootUi.Off))
        assertFalse(DeviceAccessPresentation.rootSwitchEnabled(DeviceAccessRootUi.GrantNotFound))
        assertFalse(DeviceAccessPresentation.rootSwitchEnabled(DeviceAccessRootUi.Refused("noRoot")))
        assertFalse(DeviceAccessPresentation.rootSwitchEnabled(DeviceAccessRootUi.Error("unavailable", "root")))

        assertTrue(DeviceAccessPresentation.rootSwitchEnabled(DeviceAccessRootUi.GrantFound))
        assertFalse("a found grant is still OFF until the user enables it",
            DeviceAccessPresentation.rootSwitchChecked(DeviceAccessRootUi.GrantFound))
    }

    @Test
    fun adbServiceAliveNeverEnablesOrChecksRoot() {
        val state = DeviceAccessPresentationState(
            accessibility = DeviceAccessAccessibilityUi.Granted,
            adb = DeviceAccessAdbUi.ServiceAlive(effectiveUid = 2000),
            root = DeviceAccessRootUi.Off,
        )
        assertFalse(DeviceAccessPresentation.rootSwitchEnabled(state.root))
        assertFalse(DeviceAccessPresentation.rootSwitchChecked(state.root))
        assertNull(DeviceAccessPresentation.rootEffectiveUid(state.root))
    }

    @Test
    fun onlyEnabledRootReportsItsUid() {
        assertEquals(0, DeviceAccessPresentation.rootEffectiveUid(DeviceAccessRootUi.Enabled(0)))
        assertNull(DeviceAccessPresentation.rootEffectiveUid(DeviceAccessRootUi.GrantFound))
    }

    @Test
    fun rootCheckIsOfferedOnlyBeforeAUsableGrantIsKnown() {
        assertTrue(DeviceAccessPresentation.rootCheckVisible(DeviceAccessRootUi.Off))
        assertTrue(DeviceAccessPresentation.rootCheckVisible(DeviceAccessRootUi.GrantNotFound))
        assertFalse(DeviceAccessPresentation.rootCheckVisible(DeviceAccessRootUi.GrantFound))
        assertFalse(DeviceAccessPresentation.rootCheckVisible(DeviceAccessRootUi.Enabled(0)))
    }

    // ------------------------------------------------------------ file ceilings

    @Test
    fun fileWritesToggleNeedsASelectedWritableRoot() {
        val system = DeviceAccessFileRootUi(
            id = "system",
            selected = true,
            labelRes = 1,
            writable = false,
            kind = DeviceAccessFileRootKindUi.SYSTEM,
        )
        val shared = DeviceAccessFileRootUi(
            id = "downloads",
            selected = true,
            labelRes = 2,
            writable = true,
            kind = DeviceAccessFileRootKindUi.SHARED,
        )
        assertFalse("a read-only system root cannot enable writes",
            DeviceAccessPresentation.fileWritesToggleEnabled(
                DeviceAccessTargetsUi(fileRoots = listOf(system))))
        assertFalse("an unselected shared root cannot enable writes",
            DeviceAccessPresentation.fileWritesToggleEnabled(
                DeviceAccessTargetsUi(fileRoots = listOf(shared.copy(selected = false)))))
        assertTrue(DeviceAccessPresentation.fileWritesToggleEnabled(
            DeviceAccessTargetsUi(fileRoots = listOf(system, shared))))
    }

    @Test
    fun appDataFolderEntryIsOnlyOfferedWhileRootIsLive() {
        val base = DeviceAccessPresentationState(
            root = DeviceAccessRootUi.Enabled(0),
            targets = DeviceAccessTargetsUi(appDataRootsAvailable = true),
        )
        assertTrue(DeviceAccessPresentation.appDataFolderAddEnabled(base))
        assertFalse("Root off", DeviceAccessPresentation.appDataFolderAddEnabled(
            base.copy(root = DeviceAccessRootUi.GrantFound)))
        assertFalse("busy", DeviceAccessPresentation.appDataFolderAddEnabled(
            base.copy(busy = DeviceAccessBusyUi.ROOT_CHECK)))
        assertFalse("host says app-data is not usable", DeviceAccessPresentation.appDataFolderAddEnabled(
            base.copy(targets = base.targets.copy(appDataRootsAvailable = false))))
    }

    // ------------------------------------------------------- task and screen

    @Test
    fun stopAndTakeOverRequireALiveTaskAndAnIdleHost() {
        val idle = DeviceAccessPresentationState()
        assertFalse(DeviceAccessPresentation.canStopTask(idle))
        assertFalse(DeviceAccessPresentation.canTakeOverTask(idle))
        assertFalse(DeviceAccessPresentation.screenScopeEnabled(idle))

        val running = DeviceAccessPresentationState(
            activeTask = DeviceAccessActiveTaskUi("Open settings", DeviceAccessTaskPhaseUi.RUNNING),
        )
        // A visible task is NOT enough: phone control is armed by an explicit
        // USER gesture, never by the model or by merely starting a run.
        assertFalse(DeviceAccessPresentation.canStopTask(running))
        assertFalse(DeviceAccessPresentation.canTakeOverTask(running))
        assertTrue(DeviceAccessPresentation.screenScopeEnabled(running))

        val armed = running.copy(taskControl = DeviceAccessTaskControlUi.ARMED)
        assertTrue(DeviceAccessPresentation.canStopTask(armed))
        assertTrue(DeviceAccessPresentation.canTakeOverTask(armed))

        assertFalse(DeviceAccessPresentation.canStopTask(
            armed.copy(busy = DeviceAccessBusyUi.TASK_STOP)))
        assertFalse(DeviceAccessPresentation.canTakeOverTask(
            armed.copy(activeTask = DeviceAccessActiveTaskUi("x", DeviceAccessTaskPhaseUi.STOPPING))))
        assertFalse(DeviceAccessPresentation.canTakeOverTask(
            armed.copy(activeTask = DeviceAccessActiveTaskUi("x", DeviceAccessTaskPhaseUi.TAKEN_OVER))))
    }

    @Test
    fun armRequiresTaskGrantAndAtLeastOneTargetApp() {
        val base = DeviceAccessPresentationState(
            accessibility = DeviceAccessAccessibilityUi.Granted,
            activeTask = DeviceAccessActiveTaskUi("Task", DeviceAccessTaskPhaseUi.RUNNING),
            targets = DeviceAccessTargetsUi(selectedPackages = setOf("com.example.app")),
        )
        assertTrue(DeviceAccessPresentation.canArmPhoneControl(base))
        assertFalse("already armed", DeviceAccessPresentation.canArmPhoneControl(
            base.copy(taskControl = DeviceAccessTaskControlUi.ARMED)))
        assertFalse("no task", DeviceAccessPresentation.canArmPhoneControl(
            base.copy(activeTask = null)))
        assertFalse("no target app", DeviceAccessPresentation.canArmPhoneControl(
            base.copy(targets = base.targets.copy(selectedPackages = emptySet()))))
        assertFalse("accessibility not granted", DeviceAccessPresentation.canArmPhoneControl(
            base.copy(accessibility = DeviceAccessAccessibilityUi.NotGranted)))
        assertFalse("busy", DeviceAccessPresentation.canArmPhoneControl(
            base.copy(busy = DeviceAccessBusyUi.PHONE_ARM)))
        assertTrue("stopped may be re-armed explicitly", DeviceAccessPresentation.canArmPhoneControl(
            base.copy(taskControl = DeviceAccessTaskControlUi.STOPPED)))
    }

    @Test
    fun pairingPortIsBoundedAndCodeNeedsBothPortAndCode() {
        assertTrue(DeviceAccessPresentation.pairingPortValid("37123"))
        assertFalse(DeviceAccessPresentation.pairingPortValid("0"))
        assertFalse(DeviceAccessPresentation.pairingPortValid(""))
        assertFalse(DeviceAccessPresentation.pairingPortValid("abc"))
        val open = DeviceAccessAdbUi.PairRequired(pairingSessionOpen = true)
        assertTrue(DeviceAccessPresentation.adbSubmitEnabled(
            "123456", "37123", open, DeviceAccessBusyUi.NONE))
        assertFalse(DeviceAccessPresentation.adbSubmitEnabled(
            "123456", "", open, DeviceAccessBusyUi.NONE))
        assertFalse(DeviceAccessPresentation.adbSubmitEnabled(
            "12345", "37123", open, DeviceAccessBusyUi.NONE))
    }

    @Test
    fun wholeScreenConsentIsShownOnlyWhileScreeningAndRequiredBeforeApi34() {
        val off = DeviceAccessPresentationState()
        assertFalse(DeviceAccessPresentation.wholeScreenConsentVisible(off))
        val on = DeviceAccessPresentationState(
            screenScope = DeviceAccessScreenScopeUi.CURRENT_TASK,
            targets = DeviceAccessTargetsUi(windowScreenshotCapable = false),
        )
        assertTrue(DeviceAccessPresentation.wholeScreenConsentVisible(on))
        assertTrue(DeviceAccessPresentation.wholeScreenConsentRequired(on))
        assertFalse(DeviceAccessPresentation.wholeScreenConsentRequired(
            on.copy(targets = on.targets.copy(windowScreenshotCapable = true))))
    }

    @Test
    fun accessibilityGrantedIsTheOnlyReadyState() {
        assertTrue(DeviceAccessPresentation.accessibilityGranted(DeviceAccessAccessibilityUi.Granted))
        assertFalse(DeviceAccessPresentation.accessibilityGranted(DeviceAccessAccessibilityUi.NotGranted))
        assertFalse(DeviceAccessPresentation.accessibilityGranted(DeviceAccessAccessibilityUi.Restricted))
        assertFalse(DeviceAccessPresentation.accessibilityGranted(DeviceAccessAccessibilityUi.Revoked))
    }

    // ------------------------------------------------------------------ error

    @Test
    fun errorDetailsShowOnlyABoundedMachineToken() {
        assertNull(DeviceAccessPresentation.errorCode(null))
        assertNull(DeviceAccessPresentation.errorCode(DeviceAccessUiError("failed")))
        assertNull(DeviceAccessPresentation.errorCode(DeviceAccessUiError("failed", "  ")))
        assertEquals("service_died-2",
            DeviceAccessPresentation.errorCode(DeviceAccessUiError("failed", "service_died-2 $ `")))
        assertEquals(96,
            DeviceAccessPresentation.errorCode(DeviceAccessUiError("failed", "x".repeat(200)))!!.length)
    }
}
