// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure JVM contract for the R3 internal Notes save notice. This is NOT an
 * App commit: it only proves the shape the App may accept. The App still
 * re-reads/digests its own working copy; byte acceptance lives in
 * NotesOfficeInternalSavePolicy.
 */
class OfficeInternalSaveHandoffPolicyTest {

    private val sha = "a".repeat(64)

    @Test
    fun acceptsOnlyTheThreeEditableWorkingCopyFormats() {
        for (format in listOf("docx", "xlsx", "pptx")) {
            assertNotNull(
                OfficeHostSaveHandoffPolicy.validateInternalSave(
                    "internal-1-abc", "session-token", 7L, format, sha, 1024L,
                ),
            )
        }
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "internal-1-abc", "session-token", 7L, "pdf", sha, 1024L,
            ),
        )
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "internal-1-abc", "session-token", 7L, "odt", sha, 1024L,
            ),
        )
    }

    @Test
    fun rejectsForeignOrMalformedIdentityAndBytes() {
        val valid = OfficeHostSaveHandoffPolicy.validateInternalSave(
            "internal-1-abc", "session-token", 7L, "docx", sha, 1024L,
        )
        assertNotNull(valid)
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "bad id", "session-token", 7L, "docx", sha, 1024L,
            ),
        )
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "internal-1-abc", "", 7L, "docx", sha, 1024L,
            ),
        )
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "internal-1-abc", "session-token", 0L, "docx", sha, 1024L,
            ),
        )
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "internal-1-abc", "session-token", 7L, "docx", sha.uppercase(), 1024L,
            ),
        )
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "internal-1-abc", "session-token", 7L, "docx", "a".repeat(63), 1024L,
            ),
        )
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "internal-1-abc", "session-token", 7L, "docx", sha, 0L,
            ),
        )
        assertNull(
            OfficeHostSaveHandoffPolicy.validateInternalSave(
                "internal-1-abc", "session-token", 7L, "docx", sha, OfficeRequestPolicy.MAX_STAGED_BYTES + 1,
            ),
        )
    }

    @Test
    fun positiveReplyVocabularyIsDisjointAndCloseAuthorizing() {
        // The viewer may close ONLY for the two positive answers; every
        // negative/refusal keeps the editor open.
        assertEquals(1, OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_ACCEPTED)
        assertEquals(2, OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_UNCHANGED)
        assertEquals(0, OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REFUSED)
        assertEquals(-1, OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REJECTED)
    }
}
