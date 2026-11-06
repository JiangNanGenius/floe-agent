// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateSuccessContinuationTest {
    private fun state(install: AppInstallState, download: AppDownloadState = AppDownloadState.Idle) = AppUpdateUiState(
        currentVersion = "0.1.0-alpha.33", autoCheckEnabled = true,
        check = AppCheckState.Idle, download = download, install = install,
        dialogVisible = false, blockingKinds = emptySet(),
    )

    @Test fun closingAnOldSuccessDoesNotPreventTheNextManualCheck() {
        assertTrue(AppUpdateCopy.manualCheckEnabled(state(AppInstallState.Succeeded("0.1.0-alpha.33"))))
        assertTrue(AppUpdateCopy.manualCheckEnabled(state(AppInstallState.Idle)))
    }

    @Test fun activeInstallationAndTransferStillBlockAnotherUpdate() {
        assertFalse(AppUpdateCopy.manualCheckEnabled(state(AppInstallState.Preparing)))
        assertFalse(AppUpdateCopy.manualCheckEnabled(state(AppInstallState.Idle,
            AppDownloadState.InProgress("0.1.0-alpha.34", 10, 100))))
    }
}
