// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class OfficeReadOnlyProtocolTest {
    @Test fun orderedReplyRecordsLoadReadonlyWithoutConfusingFalseWithMissing() {
        assertEquals(false, OfficeReadOnlyProtocol.barrierReport("""commandvalues: {"commandName":".uno:ReadOnly","success":"false"}""".toByteArray()))
        assertEquals(true, OfficeReadOnlyProtocol.barrierReport("""commandvalues: {"commandName":".uno:ReadOnly","success":true}""".toByteArray()))
        assertNull(OfficeReadOnlyProtocol.barrierReport("""commandvalues: {"commandName":".uno:Other","success":true}""".toByteArray()))
        assertNull(OfficeReadOnlyProtocol.barrierReport("""commandvalues: {"commandName":".uno:ReadOnly","success":"unknown"}""".toByteArray()))
    }

    @Test fun fontCacheUsesActualSecondaryUserDataDirectory() {
        val original = "<cachedir>/data/data/com.collabora.libreoffice/fontconfig</cachedir>"
        val actual = OfficePayloadBootstrap.rewriteFontsConf(original, "com.floe.agent.full", "/data/user/11/com.floe.agent.full")
        assertEquals("<cachedir>/data/user/11/com.floe.agent.full/fontconfig</cachedir>", actual)
        assertFalse(actual.contains("/data/data/"))
    }

    @Test fun nativeLoadCannotSwitchSnapshotOrAcquireRemoteAuthority() {
        val snapshot = File("/private/office/document.docx")
        assertTrue(OfficeReadOnlyProtocol.matchesSnapshotLoad("load url=file:///private/office/document.docx lang=en", snapshot))
        assertTrue(OfficeReadOnlyProtocol.matchesSnapshotLoad("load url=file%3A%2F%2F%2Fprivate%2Foffice%2Fdocument.docx", snapshot))
        for (url in listOf("https://example.org/document.docx", "file://host/private/office/document.docx", "file:///private/office/other.docx", "file:///private/office/document.docx?x=1", "file:///private/office/document.docx#part")) {
            assertFalse(url, OfficeReadOnlyProtocol.matchesSnapshotLoad("load url=$url", snapshot))
        }
    }

    @Test fun browserCannotEnableEditsOrRunUnknownMutationThroughPreviewGate() {
        for (command in listOf("uno .uno:Paste", "uno .uno:Cut", "uno .uno:DeleteRows", "uno .uno:InsertText text=x", "setviewreadonly value=false", "allowlinkupdate", "editwithpassword password=x", "future-mutation x=y", "status\nuno .uno:Paste")) {
            assertNotEquals(command, CoolMessageGate.Decision.FORWARD, CoolMessageGate.decide(command, true).decision)
        }
        for (command in listOf("tilecombine nviewid=0", "clientvisiblearea x=0 y=0 width=100 height=100", "uno .uno:Copy", "uno .uno:Zoom")) {
            assertEquals(command, CoolMessageGate.Decision.FORWARD, CoolMessageGate.decide(command, true).decision)
        }
    }
}
