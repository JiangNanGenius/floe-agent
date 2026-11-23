// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceWorkspaceMergeTest {
    @Test
    fun workspaceGrantAcceptsTheNativeScopeAndRefusesPaths() {
        val native = "floe.workspace.v1.${"0123456789abcdef".repeat(4)}"
        assertTrue(DeviceHistoryPreferenceStore.validScope(native))
        assertFalse(DeviceHistoryPreferenceStore.validScope(native.dropLast(1)))
        assertFalse(DeviceHistoryPreferenceStore.validScope("../$native"))
    }

    @Test
    fun onlyMatchingOrCommonLocalFilesMayAdvanceTheBase() {
        assertEquals(WorkspaceFileMerge.AGREED, mergeWorkspaceFile("file", "peer", null, "peer"))
        assertEquals(WorkspaceFileMerge.CREATE, mergeWorkspaceFile("missing", null, null, "peer"))
        assertEquals(WorkspaceFileMerge.REPLACE, mergeWorkspaceFile("file", "base", "base", "peer"))
        assertEquals(WorkspaceFileMerge.RETAIN, mergeWorkspaceFile("file", "mine", "base", "base"))
        assertEquals(WorkspaceFileMerge.CONFLICT, mergeWorkspaceFile("file", "mine", "base", "peer"))
    }

    @Test
    fun aLocalDeletionOrStructuralConflictNeverGetsReplaced() {
        assertEquals(WorkspaceFileMerge.RETAIN, mergeWorkspaceFile("missing", null, "base", "base"))
        assertEquals(WorkspaceFileMerge.CONFLICT, mergeWorkspaceFile("missing", null, "base", "peer"))
        assertEquals(WorkspaceFileMerge.CONFLICT, mergeWorkspaceFile("directory", null, null, "peer"))
        assertEquals(WorkspaceFileMerge.CONFLICT, mergeWorkspaceFile("blocked", null, null, "peer"))
    }
}
