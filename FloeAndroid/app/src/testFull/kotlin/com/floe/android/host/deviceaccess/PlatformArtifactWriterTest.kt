// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Full screenshot writer must commit REAL bytes to the actual bound root,
 * return the true size/digest, keep the EXISTING VNCArtifacts namespace and fail
 * closed when the trusted root is absent or the MIME/signature lies.
 */
class PlatformArtifactWriterTest {

    private val root: File = Files.createTempDirectory("floe-platform-artifact").toFile()

    @After
    fun cleanup() {
        root.deleteRecursively()
    }

    @Test
    fun jpegIsCommittedUnderVncArtifactsWithRealDigestAndSize() {
        val bytes = jpegBytes(2048)
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        val result = PlatformArtifactWriter.write(root.absolutePath, bytes, "image/jpeg")
        assertTrue(result is PlatformArtifactWriter.Result.Ok)
        val artifact = (result as PlatformArtifactWriter.Result.Ok).artifact
        assertTrue(artifact.relativePath.startsWith("VNCArtifacts/"))
        assertTrue(artifact.relativePath.endsWith(".jpg"))
        assertEquals("image/jpeg", artifact.mimeType)
        assertEquals(bytes.size, artifact.byteCount)
        assertEquals(digest, artifact.sha256)
        val committed = File(root, artifact.relativePath)
        assertTrue(committed.isFile)
        assertEquals(bytes.size.toLong(), committed.length())
    }

    @Test
    fun pngSignatureIsAcceptedAndKeptAsPng() {
        val bytes = pngBytes(512)
        val result = PlatformArtifactWriter.write(root.absolutePath, bytes, "image/png")
        assertTrue(result is PlatformArtifactWriter.Result.Ok)
        val artifact = (result as PlatformArtifactWriter.Result.Ok).artifact
        assertTrue(artifact.relativePath.endsWith(".png"))
        assertEquals(bytes.size, artifact.byteCount)
    }

    @Test
    fun unboundOrPrivateRootFailsClosed() {
        assertTrue(PlatformArtifactWriter.write(null, jpegBytes(64), "image/jpeg")
            is PlatformArtifactWriter.Result.Failed)
        assertTrue(PlatformArtifactWriter.write("", jpegBytes(64), "image/jpeg")
            is PlatformArtifactWriter.Result.Failed)
        assertTrue(PlatformArtifactWriter.write("relative/path", jpegBytes(64), "image/jpeg")
            is PlatformArtifactWriter.Result.Failed)
    }

    @Test
    fun wrongMimeOrForgedSignatureNeverCommits() {
        val bytes = jpegBytes(128)
        assertTrue(PlatformArtifactWriter.write(root.absolutePath, bytes, "image/gif")
            is PlatformArtifactWriter.Result.Failed)
        assertTrue(PlatformArtifactWriter.write(root.absolutePath, ByteArray(32), "image/jpeg")
            is PlatformArtifactWriter.Result.Failed)
        assertTrue(PlatformArtifactWriter.write(root.absolutePath, ByteArray(32), "image/png")
            is PlatformArtifactWriter.Result.Failed)
    }

    private fun jpegBytes(size: Int): ByteArray {
        require(size >= 8)
        val bytes = ByteArray(size) { 0x20 }
        bytes[0] = 0xFF.toByte()
        bytes[1] = 0xD8.toByte()
        bytes[size - 2] = 0xFF.toByte()
        bytes[size - 1] = 0xD9.toByte()
        return bytes
    }

    private fun pngBytes(size: Int): ByteArray {
        require(size >= 16)
        val bytes = ByteArray(size) { 0x11 }
        bytes[0] = 0x89.toByte()
        bytes[1] = 0x50.toByte()
        bytes[2] = 0x4E.toByte()
        bytes[3] = 0x47.toByte()
        bytes[4] = 0x0D.toByte()
        bytes[5] = 0x0A.toByte()
        bytes[6] = 0x1A.toByte()
        bytes[7] = 0x0A.toByte()
        return bytes
    }
}
