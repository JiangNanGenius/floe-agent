// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.optionalsplit

import org.junit.Assert.*
import org.junit.Test

class ComponentDocumentReturnPolicyTest {
    private val process = "00000000-0000-0000-0000-000000000001"
    private val otherProcess = "00000000-0000-0000-0000-000000000002"
    private val value = ComponentDocumentReturn(
        "10000000-0000-0000-0000-000000000001", "cadpreview",
        "20000000-0000-0000-0000-000000000001", "30000000-0000-0000-0000-000000000001",
        "模型/Part.STL", 65, 1000, process, 42)
    private fun restores(v: ComponentDocumentReturn = value, now: Long = 2000,
                         version: Long = 65, process: String = otherProcess,
                         installed: Boolean = true) =
        ComponentDocumentReturnPolicy.mayRestore(v, now, version, process, installed)

    @Test fun actualInstalledComponentInNewProcessCanReturn() {
        assertTrue(restores())
        assertTrue(restores(value.copy(module = "officepreview", path = "报告.xlsx")))
    }

    @Test fun stagedDownloadAndSameProcessCannotResurrect() {
        assertFalse(restores(value.copy(installSession = null)))
        assertFalse(restores(process = process))
        assertFalse(restores(installed = false))
    }

    @Test fun packageChangeExpiredRecordAndClockRollbackCannotReturn() {
        assertFalse(restores(version = 66))
        assertFalse(restores(now = 999))
        assertTrue(restores(now = 1000 + ComponentDocumentReturnPolicy.MAX_AGE))
        assertFalse(restores(now = 1001 + ComponentDocumentReturnPolicy.MAX_AGE))
    }

    @Test fun ownerRequiresBothActualTaskAndWorkspace() {
        assertTrue(ComponentDocumentReturnPolicy.owns(value, value.taskID, value.workspaceID))
        assertFalse(ComponentDocumentReturnPolicy.owns(value, otherProcess, value.workspaceID))
        assertFalse(ComponentDocumentReturnPolicy.owns(value, value.taskID, otherProcess))
    }

    @Test fun metadataCannotIntroduceAbsoluteOrTraversingPaths() {
        for (path in listOf("/sdcard/part.stl", "../part.stl", "a/../part.stl", "a//part.stl",
                "./part.stl", "a\\part.stl", "part\u0000.stl")) {
            assertFalse(path, restores(value.copy(path = path)))
        }
        assertFalse(restores(value.copy(taskID = "untrusted-task")))
        assertFalse(restores(value.copy(installSession = -1)))
    }

    @Test fun componentAndDocumentFormatMustAgree() {
        assertFalse(restores(value.copy(module = "officepreview")))
        assertFalse(restores(value.copy(path = "report.docx")))
        assertFalse(restores(value.copy(module = "arbitrary")))
    }
}
