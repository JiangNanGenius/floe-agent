// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.sftp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SftpBrowserModelsTest {
    @Test
    fun byteTextUsesBinaryUnits() {
        assertEquals("0 B", sftpBytesText(0))
        assertEquals("1 KB", sftpBytesText(1024))
        assertEquals("1.0 MB", sftpBytesText(1024L * 1024))
    }

    @Test
    fun initialStateIsUnavailableNotAnEmptySuccess() {
        val state = SftpBrowserUiState()
        assertFalse(state.coreReady)
        assertEquals(null, state.lane)
        assertEquals(emptyList<SftpEntryUi>(), state.entries)
    }
}
