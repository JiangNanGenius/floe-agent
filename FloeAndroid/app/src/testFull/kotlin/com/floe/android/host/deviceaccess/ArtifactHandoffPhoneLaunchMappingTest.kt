// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.host.externaledit.ArtifactHandoffBackgroundLaunchResult
import com.floe.android.phonecontrol.PhoneControlActionResult
import com.floe.android.phonecontrol.PhoneControlDenial
import com.floe.android.phonecontrol.PhoneControlDispatch
import com.floe.android.phonecontrol.PhoneControlFailure
import com.floe.android.phonecontrol.PhoneControlResult
import com.floe.android.phonecontrol.PhoneControlUnavailable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The background handoff must keep "definitely not dispatched" separate from
 * "OS outcome unknown". A mistaken retry after the latter duplicates a viewer
 * or importer effect; a refusal of the former must remain safely retryable.
 */
class ArtifactHandoffPhoneLaunchMappingTest {
    private fun result(dispatch: PhoneControlDispatch) =
        PhoneControlResult.Ok(PhoneControlActionResult(
            "documentView", dispatch, null, null, null, null))

    private fun refused(result: ArtifactHandoffBackgroundLaunchResult): String {
        assertTrue(result is ArtifactHandoffBackgroundLaunchResult.Refused)
        return (result as ArtifactHandoffBackgroundLaunchResult.Refused).code
    }

    @Test
    fun acceptedStartIsTheOnlySuccess() {
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Accepted(),
            artifactHandoffDeviceLaunchResult(result(PhoneControlDispatch.ACCEPTED)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffDeviceLaunchResult(result(PhoneControlDispatch.UNKNOWN)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffDeviceLaunchResult(result(PhoneControlDispatch.PARTIAL)))
        assertEquals("launchRejected",
            refused(artifactHandoffDeviceLaunchResult(result(PhoneControlDispatch.NOT_DISPATCHED))))
        assertEquals("launchRejected",
            refused(artifactHandoffDeviceLaunchResult(result(PhoneControlDispatch.REJECTED))))
    }

    @Test
    fun definiteDispatchesMapToTypedRetryableRefusals() {
        assertEquals("stoppedByUser", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.STOPPED))))
        assertEquals("humanTakeover", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.TAKEN_OVER))))
        assertEquals("humanTakeover", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.USER_TOUCH))))
        assertEquals("deviceLocked", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED))))
        assertEquals("deviceArmRequired", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED))))
        assertEquals("deviceArmRequired", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_STALE))))
        assertEquals("targetNotPermitted", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED))))
        assertEquals("targetNotPermitted", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.PROTECTED_WINDOW))))
        assertEquals("deviceBusy", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN))))
        assertEquals("deviceBusy", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Denied(PhoneControlDenial.OPERATION_IN_FLIGHT))))
        assertEquals("deviceServiceNotReady", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED))))
        assertEquals("targetNotPermitted", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Unavailable(PhoneControlUnavailable.LAUNCH_TARGET_UNAVAILABLE))))
        assertEquals("launchRejected", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Failed(PhoneControlFailure.ACTION_REJECTED))))
        assertEquals("cancelled", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Failed(PhoneControlFailure.CANCELLED))))
    }

    @Test
    fun onlyTheClosedStartRejectionIsRetryable() {
        // The device session emits ACTION_REJECTED ONLY for its closed
        // ActivityNotFoundException/SecurityException boundary. Any other
        // start/post-start exception is INTERNAL_ERROR and therefore unknown.
        assertEquals("launchRejected", refused(artifactHandoffDeviceLaunchResult(
            PhoneControlResult.Failed(PhoneControlFailure.ACTION_REJECTED))))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffDeviceLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.OBSERVATION_FAILED)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffDeviceLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.GESTURE_TIMEOUT)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffDeviceLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.CAPTURE_SECURE_WINDOW)))
    }

    @Test
    fun unobservableFailuresAreUnknownNotRetryable() {
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffDeviceLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.INTERNAL_ERROR)))
        assertEquals(ArtifactHandoffBackgroundLaunchResult.Unknown,
            artifactHandoffDeviceLaunchResult(
                PhoneControlResult.Failed(PhoneControlFailure.TIMEOUT)))
    }

}
