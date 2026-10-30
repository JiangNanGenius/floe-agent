// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.io.File
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WorkspaceOfficeSnapshotStagerTest {
    @get:Rule val temporary = TemporaryFolder()
    private val owner = WorkspaceOfficeSnapshotStager.Owner(
        UUID.randomUUID().toString(), UUID.randomUUID().toString(), 42, 7)
    private val body = ByteArray(145_003) { (it % 251).toByte() }

    private inner class Transport : WorkspaceOfficeSnapshotStager.Channel {
        var opens = 0
        var closes = 0
        var closeStatus = 0
        var size = body.size.toLong()
        var path = "Reports/report.docx"
        var sha = MessageDigest.getInstance("SHA-256").digest(body).joinToString("") { "%02x".format(it) }
        var afterRead: () -> Unit = {}
        var extraEOF = false
        override fun open(owner: WorkspaceOfficeSnapshotStager.Owner, path: String): Long {
            assertEquals(this@WorkspaceOfficeSnapshotStagerTest.owner, owner)
            assertEquals(this.path, path)
            opens++
            return 123
        }
        override fun info(ticket: Long, reply: ByteArray): Int {
            assertEquals(123L, ticket)
            val json = """{"ok":1,"mode":"export","logicalPath":"$path","sha256":"$sha","bytes":$size}""".toByteArray()
            json.copyInto(reply)
            return json.size
        }
        override fun read(ticket: Long, offset: Long, target: ByteArray): Int {
            assertEquals(123L, ticket)
            assertTrue(target.size <= 64 * 1024)
            if (offset == body.size.toLong()) return if (extraEOF) 1 else 0
            // Deliberately short chunks, including arbitrary binary bytes.
            val count = minOf(7777, body.size - offset.toInt())
            body.copyInto(target, 0, offset.toInt(), offset.toInt() + count)
            afterRead()
            return count
        }
        override fun close(ticket: Long): Int {
            assertEquals(123L, ticket)
            closes++
            return closeStatus
        }
    }

    private fun expectFailure(block: () -> Unit): WorkspaceOfficeSnapshotStager.Failure {
        try { block() } catch (error: WorkspaceOfficeSnapshotStager.Failure) { return error }
        throw AssertionError("Expected a typed snapshot refusal")
    }

    @Test fun binaryChunksAreVerifiedWithoutUTF8AndOriginalIsUntouched() {
        val original = temporary.newFile("original.docx").apply { writeBytes(body) }
        val root = File(temporary.root, "snapshots")
        val channel = Transport()
        val snapshot = WorkspaceOfficeSnapshotStager(root, channel).stage(owner, "Reports/report.docx") { true }
        assertArrayEquals(body, snapshot.file.readBytes())
        assertArrayEquals(body, original.readBytes())
        assertEquals(channel.sha, snapshot.sha256)
        assertEquals(owner, snapshot.owner)
        assertNull(snapshot.sourceRevision) // Never invent a source CAS revision.
        assertEquals(1, channel.closes)
    }

    @Test fun digestMismatchReleasesExactTicketAndDeletesUnexposedCopy() {
        val root = temporary.newFolder()
        val channel = Transport().apply { sha = "0".repeat(64) }
        val failure = expectFailure {
            WorkspaceOfficeSnapshotStager(root, channel).stage(owner, "Reports/report.docx") { true }
        }
        assertEquals("snapshotDigestMismatch", failure.code)
        assertEquals(1, channel.closes)
        assertTrue(root.listFiles()!!.isEmpty())
    }

    @Test fun ownerRetirementDuringReadCannotPublishSnapshot() {
        var current = true
        val root = temporary.newFolder()
        val channel = Transport().apply { afterRead = { current = false } }
        val failure = expectFailure {
            WorkspaceOfficeSnapshotStager(root, channel).stage(owner, "Reports/report.docx") { current }
        }
        assertEquals("ownerChanged", failure.code)
        assertEquals(1, channel.closes)
        assertTrue(root.listFiles()!!.isEmpty())
    }

    @Test fun oversizedNativeSnapshotIsRefusedBeforeCreatingFile() {
        val root = temporary.newFolder()
        val channel = Transport().apply { size = WorkspaceOfficeSnapshotStager.MAX_BYTES + 1 }
        assertEquals("contentTooLarge", expectFailure {
            WorkspaceOfficeSnapshotStager(root, channel).stage(owner, "Reports/report.docx") { true }
        }.code)
        assertEquals(1, channel.closes)
        assertTrue(root.listFiles()!!.isEmpty())
    }

    @Test fun failedCloseDoesNotBecomeSuccessfulPreviewInput() {
        val root = temporary.newFolder()
        val channel = Transport().apply { closeStatus = -518 }
        assertEquals("snapshotCloseRefused:-518", expectFailure {
            WorkspaceOfficeSnapshotStager(root, channel).stage(owner, "Reports/report.docx") { true }
        }.code)
        assertEquals(1, channel.closes)
        assertTrue(root.listFiles()!!.isEmpty())
    }

    @Test fun extraBytesBeyondDeclaredLengthAreNotIgnored() {
        val root = temporary.newFolder()
        val channel = Transport().apply { extraEOF = true }
        assertEquals("snapshotLengthMismatch", expectFailure {
            WorkspaceOfficeSnapshotStager(root, channel).stage(owner, "Reports/report.docx") { true }
        }.code)
        assertEquals(1, channel.closes)
        assertTrue(root.listFiles()!!.isEmpty())
    }

    @Test fun pathTraversalNeverOpensNativeTransfer() {
        val channel = Transport()
        val stager = WorkspaceOfficeSnapshotStager(temporary.newFolder(), channel)
        for (path in listOf("../report.docx", "/report.docx", "Reports//report.docx", "Reports/a.txt", "a\\b.docx")) {
            assertEquals("invalidOfficePath", expectFailure { stager.stage(owner, path) { true } }.code)
        }
        assertEquals(0, channel.opens)
        assertEquals(0, channel.closes)
    }

    @Test fun defaultPurposeStaysTheReviewedOfficeTriple() {
        // Adding preview purposes must not widen the existing Office open:
        // PDF/image paths are refused BEFORE any native egress is opened.
        val channel = Transport()
        val stager = WorkspaceOfficeSnapshotStager(temporary.newFolder(), channel)
        for (path in listOf("Reports/report.pdf", "shots/frame.png", "data/report.xlsm")) {
            assertEquals("invalidOfficePath", expectFailure { stager.stage(owner, path) { true } }.code)
        }
        assertEquals(0, channel.opens)
    }

    @Test fun explicitPdfPurposeAcceptsOnlyItsOwnFormatAndKeepsTheExtension() {
        val channel = Transport().apply { path = "Reports/report.pdf" }
        val root = temporary.newFolder()
        val snapshot = WorkspaceOfficeSnapshotStager(root, channel).stage(
            owner = owner,
            relativePath = "Reports/report.pdf",
            formats = setOf("pdf"),
            isCurrent = { true },
        )
        assertEquals("document.pdf", snapshot.file.name)
        assertEquals(1, channel.opens)
        assertEquals(1, channel.closes)
        assertArrayEquals(body, snapshot.file.readBytes())
        // A PDF-purpose instance must NOT silently accept an Office name.
        channel.path = "Reports/report.docx"
        val other = WorkspaceOfficeSnapshotStager(root, channel)
        assertEquals("invalidOfficePath", expectFailure {
            other.stage(owner, "Reports/report.docx", setOf("pdf")) { true }
        }.code)
    }

    @Test fun explicitImagePurposeUsesItsTighterCapBeforePublishingAnything() {
        val channel = Transport().apply { path = "shots/frame.PNG" }
        val root = temporary.newFolder()
        val stager = WorkspaceOfficeSnapshotStager(root, channel)
        val accepted = stager.stage(
            owner = owner,
            relativePath = "shots/frame.PNG",
            formats = setOf("png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif"),
            maxBytes = body.size.toLong(),
            isCurrent = { true },
        )
        assertEquals("document.png", accepted.file.name)
        // One byte over the caller's closed cap is refused before a
        // snapshot directory is created (the channel open is released).
        val oversize = Transport().apply {
            path = "shots/frame.png"
            size = body.size.toLong() + 1
        }
        val cap = body.size.toLong()
        assertEquals("contentTooLarge", expectFailure {
            WorkspaceOfficeSnapshotStager(root, oversize).stage(
                owner = owner,
                relativePath = "shots/frame.png",
                formats = setOf("png"),
                maxBytes = cap,
                isCurrent = { true },
            )
        }.code)
        assertEquals(1, oversize.closes)
        assertEquals(1, root.listFiles()!!.size) // only the accepted snapshot remains
    }
}
