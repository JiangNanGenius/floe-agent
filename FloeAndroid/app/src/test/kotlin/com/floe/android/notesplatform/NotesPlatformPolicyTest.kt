// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotesPlatformPolicyTest {

    @Test
    fun safeNamesNeverBecomePathsAndKeepTheExtension() {
        assertEquals("b.pdf", NotesPlatformNames.safeFileName("a/b.pdf"))
        assertEquals("note.pdf", NotesPlatformNames.safeFileName("../../note.pdf"))
        assertEquals("file.txt", NotesPlatformNames.safeFileName("file", "fallback", "txt"))
        assertTrue(NotesPlatformNames.safeFileName("x".repeat(500), "n", "pdf").length <= 200)
        assertEquals("note", NotesPlatformNames.safeFileName("   ", "note"))
        assertFalse(NotesPlatformNames.safeFileName("a\\b").contains('\\'))
    }

    @Test
    fun mimeAndExtensionStayConcrete() {
        assertEquals("application/pdf", NotesPlatformNames.mimeFor("a.PDF"))
        assertEquals("image/jpeg", NotesPlatformNames.mimeFor("no-extension", "image/jpeg"))
        assertEquals("application/octet-stream", NotesPlatformNames.mimeFor("file.bin", "*/*"))
        assertEquals("docx", NotesPlatformNames.extensionForMime(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ))
        assertNull(NotesPlatformNames.extensionForMime("*/*"))
        assertTrue(NotesPlatformNames.isOfficeEditable("a.pptx"))
        assertFalse(NotesPlatformNames.isOfficeEditable("a.pdf"))
    }

    @Test
    fun officeReadbackPolicyNeverClaimsAnUnobservedSave() {
        fun decide(
            result: Boolean = true,
            token: Boolean = true,
            clean: Boolean = true,
            failure: String? = null,
            changed: Boolean = true,
            explicit: Boolean = true,
            valid: Boolean = true,
            acked: Boolean = false,
        ) = NotesOfficeReadbackPolicy.decide(
            resultPresent = result,
            tokenMatches = token,
            closedCleanly = clean,
            failureCode = failure,
            digestChanged = changed,
            explicitSaveCompleted = explicit,
            validOoxml = valid,
            userCloseAcknowledged = acked,
        )

        assertEquals(NotesOfficeReadbackDecision.SAVED, decide())
        assertEquals(NotesOfficeReadbackDecision.SAVED, decide(changed = false))
        assertEquals(NotesOfficeReadbackDecision.UNCHANGED, decide(explicit = false, changed = false))
        assertEquals(NotesOfficeReadbackDecision.UNSAVED_AT_CLOSE, decide(explicit = false))
        assertEquals(NotesOfficeReadbackDecision.INVALID_SAVED_COPY, decide(valid = false))
        assertEquals(NotesOfficeReadbackDecision.EDITOR_FAILED, decide(failure = "LOAD_ERROR"))
        assertEquals(NotesOfficeReadbackDecision.EDITOR_UNCLEAN, decide(clean = false))
        assertEquals(NotesOfficeReadbackDecision.MISSING_RESULT, decide(result = false))
        assertEquals(NotesOfficeReadbackDecision.STALE_RESULT, decide(token = false))
        // A failure never gets re-labelled as a clean close/save without an
        // exact acknowledged user close.
        assertEquals(NotesOfficeReadbackDecision.EDITOR_FAILED, decide(failure = "X", clean = false))

        // R3 close-bypass cases. The pinned last-session BYE can exit before
        // setResult; an exact OfficeCloseAck acknowledgement makes that a
        // known user close, never an inferred clean close.
        assertEquals(NotesOfficeReadbackDecision.SAVED, decide(result = false, acked = true))
        assertEquals(
            "a verified close never bypasses the OOXML check",
            NotesOfficeReadbackDecision.INVALID_SAVED_COPY,
            decide(result = false, acked = true, valid = false),
        )
        assertEquals(NotesOfficeReadbackDecision.SAVED, decide(failure = "PROCESS_LOST", clean = false, acked = true))
        assertEquals(NotesOfficeReadbackDecision.SAVED, decide(failure = "TRANSPORT_FAILURE", clean = false, acked = true))
        assertEquals(
            "a missing result without the exact close ack stays an unexpected failure",
            NotesOfficeReadbackDecision.MISSING_RESULT,
            decide(result = false, acked = false),
        )
        assertEquals(
            "a real cancel is never turned into a save by the close ack",
            NotesOfficeReadbackDecision.EDITOR_FAILED,
            decide(failure = "SESSION_CANCELLED", clean = false, acked = true),
        )
        assertEquals(
            "a foreign Activity result is never imported even after an owned close",
            NotesOfficeReadbackDecision.STALE_RESULT,
            decide(token = false, acked = true),
        )
        assertEquals(
            "a plain acknowledged close with an unchanged working copy is not an error",
            NotesOfficeReadbackDecision.UNCHANGED,
            decide(result = false, changed = false, explicit = false, acked = true),
        )
        assertEquals(
            "a discard/autosave changed copy is still never imported",
            NotesOfficeReadbackDecision.UNSAVED_AT_CLOSE,
            decide(result = false, changed = true, explicit = false, acked = true),
        )
        assertEquals(
            "an unacknowledged missing result stays a failure even when the working copy is unchanged",
            NotesOfficeReadbackDecision.MISSING_RESULT,
            decide(result = false, changed = false, explicit = false, acked = false),
        )
    }

    @Test
    fun internalSavePolicyVerifiesTheExactOwnedBytesBeforeAnyImport() {
        fun decide(
            expectedFormat: String? = "docx",
            noticeFormat: String? = "docx",
            noticeSha: String? = "a".repeat(64),
            noticeBytes: Long = 200_000L,
            actualSha: String? = "a".repeat(64),
            actualBytes: Long = 200_000L,
            baseSha: String? = "b".repeat(64),
            maxBytes: Long = 64L * 1024 * 1024,
        ) = NotesOfficeInternalSavePolicy.decide(
            expectedFormat = expectedFormat,
            noticeFormat = noticeFormat,
            noticeSha256 = noticeSha,
            noticeBytes = noticeBytes,
            actualSha256 = actualSha,
            actualBytes = actualBytes,
            baseSha256 = baseSha,
            maxBytes = maxBytes,
        )

        assertEquals(NotesOfficeInternalSaveDecision.ACCEPTED, decide())
        assertEquals(NotesOfficeInternalSaveDecision.REJECTED, decide(noticeFormat = "xlsx"))
        assertEquals(NotesOfficeInternalSaveDecision.REJECTED, decide(expectedFormat = null))
        assertEquals(NotesOfficeInternalSaveDecision.REJECTED, decide(actualSha = "c".repeat(64)))
        assertEquals(NotesOfficeInternalSaveDecision.REJECTED, decide(actualBytes = 199_999L))
        assertEquals(NotesOfficeInternalSaveDecision.REJECTED, decide(noticeBytes = 0L))
        assertEquals(NotesOfficeInternalSaveDecision.REJECTED, decide(noticeBytes = 65L * 1024 * 1024, actualBytes = 65L * 1024 * 1024))
        // Even bytes equal to the base are refused if the engine receipt
        // describes a different digest; unchanged also requires exact proof.
        assertEquals(NotesOfficeInternalSaveDecision.REJECTED, decide(actualSha = "b".repeat(64)))
        assertEquals(
            NotesOfficeInternalSaveDecision.UNCHANGED,
            decide(noticeSha = "b".repeat(64), actualSha = "b".repeat(64)),
        )
    }

    @Test
    fun fileCopyIsAtomicAndReadBackFromTheDestination() {
        val root = java.nio.file.Files.createTempDirectory("notes-copy-test").toFile()
        val source = java.io.File(root, "source.bin")
        source.writeBytes(ByteArray(200_000) { (it % 251).toByte() })
        val destination = java.io.File(root, "out.bin")
        val staged = NotesPlatformFiles.copyFileDurable(source, destination, 1_000_000)
        assertEquals(200_000L, staged.byteCount)
        assertEquals(NotesPlatformFiles.sha256(source), staged.sha256)
        assertTrue(destination.isFile)
        assertFalse(root.listFiles().orEmpty().any { it.name.contains(".part-") })
    }
}
