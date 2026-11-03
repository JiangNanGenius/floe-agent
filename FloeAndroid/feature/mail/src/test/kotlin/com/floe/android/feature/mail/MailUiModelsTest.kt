// SPDX-License-Identifier: MPL-2.0
//
// C06 presentation value tests. Authored source; NOT RUN by this lane.

package com.floe.android.feature.mail

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MailUiModelsTest {
    @Test
    fun folderSpecialUseIsReadFromServerAttributes() {
        assertEquals("Archive", MailFolderRow("Archive", listOf("\\Archive")).specialLabel())
        assertEquals("Trash", MailFolderRow("Bin", listOf("\\Trash")).specialLabel())
        assertEquals(null, MailFolderRow("INBOX", emptyList()).specialLabel())
    }

    @Test
    fun rowFlagsAreCaseInsensitive() {
        val row = MailRow("9", 120, listOf("\\Seen", "\\Flagged"))
        assertTrue(row.seen)
        assertTrue(row.flagged)
        assertFalse(MailRow("10", 1, emptyList()).seen)
    }

    @Test
    fun accountPortDefaultsFollowProtocolAndTls() {
        assertEquals(993, defaultPort("imap", "implicitTLS"))
        assertEquals(143, defaultPort("imap", "startTLS"))
        assertEquals(995, defaultPort("pop3", "implicitTLS"))
        assertEquals(110, defaultPort("pop3", "startTLS"))
    }
}
