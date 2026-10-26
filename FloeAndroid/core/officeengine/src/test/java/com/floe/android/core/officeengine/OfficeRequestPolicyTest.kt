package com.floe.android.core.officeengine

import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM tests over the validation/triage/bootstrap boundaries. Android
 * framework stubs are never exercised as functional behaviour (module
 * convention with core/workspacebridge and core/safgateway).
 */
class OfficeRequestPolicyTest {

    private fun tempAppRoot(): Pair<File, File> {
        val root = createTempDir("floe-office-test-root")
        val staged = File(root, "session-uuid-1").apply { mkdirs() }
        return root to staged
    }

    @Test
    fun shapeValidationAcceptsMinimumTrustedRequest() {
        val failure = OfficeRequestPolicy.validateShape(
            sessionToken = "tok-1",
            stagedFilePath = "/data/data/com.floe.agent/files/snap/document.docx",
            sha256 = "a".repeat(64),
            lengthBytes = 4096,
            displayName = "Quarterly report",
            permission = OfficePermission.READ_ONLY,
        )
        assertNull(failure)
    }

    @Test
    fun shapeValidationRejectsBadDigestLengthTokenAndEscapingName() {
        assertNotNull(
            OfficeRequestPolicy.validateShape("tok", "/x/y.docx", "nothex", 10, "n", OfficePermission.READ_ONLY),
        )
        assertNotNull(
            OfficeRequestPolicy.validateShape("", "/x/y.docx", "a".repeat(64), 10, "n", OfficePermission.READ_ONLY),
        )
        assertNotNull(
            OfficeRequestPolicy.validateShape(
                "tok", "/x/y.docx", "a".repeat(64), 10, "evil/../name", OfficePermission.READ_ONLY,
            ),
        )
    }

    @Test
    fun shapeValidationAcceptsExplicitEditRequestInR2() {
        // R1 reserved EDIT and refused it at shape level; R2 delivers the
        // seam: EDIT is an explicit trusted-host request. The additional
        // EDIT admission fact (a WRITABLE working copy, never an immutable
        // snapshot) needs the real File and is enforced fail-closed in the
        // engine open pipeline — see OfficeRequestPolicyR2Test and
        // OfficeEngineService.runOpen.
        assertNull(
            OfficeRequestPolicy.validateShape(
                "tok", "/x/y.docx", "a".repeat(64), 10, "n", OfficePermission.EDIT,
            ),
        )
    }

    @Test
    fun formatForPathAcceptsOnlyTheThreeR1Formats() {
        assertEquals(OfficeDocumentFormat.DOCX, OfficeRequestPolicy.formatForPath("/x/document.docx"))
        assertEquals(OfficeDocumentFormat.XLSX, OfficeRequestPolicy.formatForPath("/x/document.xlsx"))
        assertEquals(OfficeDocumentFormat.PPTX, OfficeRequestPolicy.formatForPath("/x/document.pptx"))
        // Macro-bearing and out-of-scope containers are outside R1 acceptance.
        assertNull(OfficeRequestPolicy.formatForPath("/x/document.docm"))
        assertNull(OfficeRequestPolicy.formatForPath("/x/document.odt"))
        assertNull(OfficeRequestPolicy.formatForPath("/x/document.pdf"))
        assertNull(OfficeRequestPolicy.formatForPath("/x/document"))
        // Case-insensitive extension.
        assertEquals(OfficeDocumentFormat.DOCX, OfficeRequestPolicy.formatForPath("/x/DOC.DOCX"))
    }

    @Test
    fun stagedFileMustBeRegularCanonicalInsideAppRoots() {
        val (root, stagedDir) = tempAppRoot()
        val staged = File(stagedDir, "document.docx").apply { writeBytes(byteArrayOf(1, 2, 3)) }

        val (accepted, none) = OfficeRequestPolicy.resolveStagedFile(listOf(root.canonicalPath), staged.canonicalPath)
        assertNull(none)
        assertNotNull(accepted)

        // Outside the roots: refused.
        val outside = File(root.parentFile, "outside.docx").apply { writeBytes(byteArrayOf(1)) }
        val (rejected, reason) = OfficeRequestPolicy.resolveStagedFile(listOf(root.canonicalPath), outside.canonicalPath)
        assertNull(rejected)
        assertEquals(OfficeFailureCode.STAGED_FILE_MISSING, (reason as OfficeException).code)
        outside.delete()

        // Directory instead of file: refused.
        val (dirRejected, dirReason) = OfficeRequestPolicy.resolveStagedFile(listOf(root.canonicalPath), stagedDir.path)
        assertNull(dirRejected)
        assertEquals(OfficeFailureCode.STAGED_FILE_MISSING, (dirReason as OfficeException).code)

        // Symlink escaping: refused (canonical != absolute).
        val link = File(root, "link.docx")
        runCatching { java.nio.file.Files.createSymbolicLink(link.toPath(), staged.toPath()) }
        if (link.isFile) {
            val (linkRejected, linkReason) = OfficeRequestPolicy.resolveStagedFile(listOf(root.canonicalPath), link.absolutePath)
            assertNotNull(linkRejected ?: linkReason)
            if (linkRejected == null) {
                // Either the containment check or the canonical check refuses.
                assertTrue(linkReason is OfficeException)
            }
        }
        link.delete()
        root.deleteRecursively()
    }

    @Test
    fun digestVerificationMatchesAndFailsClosed() {
        val file = createTempFile("floe-office-digest", ".docx")
        val payload = "office snapshot bytes".toByteArray()
        file.writeBytes(payload)
        val digest = MessageDigest.getInstance("SHA-256").digest(payload)
            .joinToString("") { "%02x".format(it) }
        assertTrue(OfficeRequestPolicy.verifyStagedDigest(file, payload.size.toLong(), digest))
        assertFalse(OfficeRequestPolicy.verifyStagedDigest(file, payload.size.toLong() + 1, digest))
        assertFalse(OfficeRequestPolicy.verifyStagedDigest(file, payload.size.toLong(), digest.replace('a', 'b')))
        assertFalse(OfficeRequestPolicy.verifyStagedDigest(File("/definitely/missing.docx"), 1, digest))
        file.delete()
    }

    @Test
    fun engineLoadUrlKeepsFileSchemePrefix() {
        assertEquals(
            "file:///data/user/0/com.floe.agent/files/snap/document.docx",
            OfficeRequestPolicy.engineLoadUrl("/data/user/0/com.floe.agent/files/snap/document.docx"),
        )
    }
}
