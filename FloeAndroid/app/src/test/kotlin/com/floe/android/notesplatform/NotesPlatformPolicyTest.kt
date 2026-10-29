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
        ) = NotesOfficeReadbackPolicy.decide(
            resultPresent = result,
            tokenMatches = token,
            closedCleanly = clean,
            failureCode = failure,
            digestChanged = changed,
            explicitSaveCompleted = explicit,
            validOoxml = valid,
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
        // A failure never gets re-labelled as a clean close/save.
        assertEquals(NotesOfficeReadbackDecision.EDITOR_FAILED, decide(failure = "X", clean = false))
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
