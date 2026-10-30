// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.Paths
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Real file-bounded FloePatch v1 round-trip against the production applier.
 * The patch bytes are written by a test-side writer that follows the same
 * documented format as `scripts/update/produce-update-delta.py`; no production
 * guard is relaxed for the fixture.
 */
class DeltaApplyTest {

    private val baseBytes = ByteArray(30_000) { (it * 31).toByte() }

    private fun target(): ByteArray {
        val changed = ByteArray(4_000) { (it * 7 + 3).toByte() }
        val appended = ByteArray(3_000) { (it * 13 + 5).toByte() }
        return baseBytes.copyOfRange(0, 10_000) + changed + baseBytes.copyOfRange(14_000, 30_000) + appended
    }

    private data class Op(
        val copy: Boolean,
        val offset: Long = 0L,
        val length: Long = 0L,
        val bytes: ByteArray = ByteArray(0),
    )

    private fun ops(): List<Op> = listOf(
        Op(copy = true, offset = 0, length = 10_000L),
        Op(copy = false, bytes = ByteArray(4_000) { (it * 7 + 3).toByte() }),
        Op(copy = true, offset = 14_000, length = 16_000L),
        Op(copy = false, bytes = ByteArray(3_000) { (it * 13 + 5).toByte() }),
    )

    private fun writePatch(
        file: File,
        baseSha: String,
        targetBytes: ByteArray,
        targetSha: String,
        ops: List<Op>,
        declareCopyBytes: Long = 26_000L,
        declareInsertBytes: Long = 7_000L,
        formatVersion: Long = 1L,
    ) {
        val header = """
            {"format":"floepatch","formatVersion":$formatVersion,
             "base":{"sha256":"$baseSha","sizeBytes":${baseBytes.size}},
             "target":{"sha256":"$targetSha","sizeBytes":${targetBytes.size}},
             "ops":{"copies":2,"copyBytes":$declareCopyBytes,"inserts":2,"insertBytes":$declareInsertBytes},
             "producer":"test"}
        """.trimIndent().replace("\n", "").toByteArray(Charsets.UTF_8)
        BufferedOutputStream(FileOutputStream(file)).use { out ->
            out.write(FloePatchFormat.MAGIC)
            writeLe32(out, header.size)
            out.write(header)
            for (op in ops) {
                if (op.copy) {
                    out.write(FloePatchFormat.OP_COPY)
                    writeLe64(out, op.offset)
                    writeLe32(out, op.length.toInt())
                } else {
                    out.write(FloePatchFormat.OP_INSERT)
                    writeLe32(out, op.bytes.size)
                    out.write(op.bytes)
                }
            }
            out.write(FloePatchFormat.OP_END)
            writeLe64(out, targetBytes.size.toLong())
        }
    }

    private fun writeLe32(out: java.io.OutputStream, value: Int) {
        for (shift in 0 until 4) out.write((value ushr (shift * 8)) and 0xFF)
    }

    private fun writeLe64(out: java.io.OutputStream, value: Long) {
        for (shift in 0 until 8) out.write(((value ushr (shift * 8)) and 0xFF).toInt())
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun manifest(baseSha: String, targetSha: String, targetBytes: ByteArray, patchBytes: Long) =
        UpdateDeltaManifest(
            schema = UpdateDeltaFormat.SCHEMA,
            channel = UpdateDeltaFormat.CHANNEL,
            packageName = "com.floe.agent.full",
            releaseTag = "android/v0.1.0-alpha.17",
            base = DeltaBaseIdentity("base.apk", baseSha, baseBytes.size.toLong(), "0.1.0-alpha.16", 18L),
            target = DeltaTargetIdentity(
                apkName = "target.apk",
                sha256 = targetSha,
                sizeBytes = targetBytes.size.toLong(),
                versionName = "0.1.0-alpha.17",
                versionCode = 19L,
                minSdk = 28,
                abis = listOf("arm64-v8a"),
                signerSha256 = listOf("a".repeat(64)),
            ),
            patch = DeltaPatch("floepatch", 1, "patch.delta", patchBytes, "b".repeat(64)),
        )

    private fun withFiles(block: (File, File, File) -> Unit) {
        val dir = Files.createTempDirectory("floe-delta-apply-").toFile()
        try {
            val base = File(dir, "base.apk").apply { writeBytes(baseBytes) }
            val patch = File(dir, "patch.delta")
            val output = File(dir, "target.partial")
            block(base, patch, output)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun overflowingVersionCannotWrapBackToVersionOne() {
        val dir = Files.createTempDirectory("delta-version-overflow").toFile()
        try {
            val base = File(dir, "base.apk").apply { writeBytes(baseBytes) }
            val patch = File(dir, "update.delta")
            val output = File(dir, "target.partial")
            val target = target()
            writePatch(patch, sha(baseBytes), target, sha(target), ops(), formatVersion = 4_294_967_297L)
            val result = FloePatchApplier().apply(base, patch, output,
                manifest(sha(baseBytes), sha(target), target, patch.length()))
            assertEquals(DeltaApplyFailure.BAD_HEADER, (result as DeltaApplyResult.Failure).reason)
            assertFalse(output.exists())
            assertArrayEquals(baseBytes, base.readBytes())
        } finally { dir.deleteRecursively() }
    }

    @Test
    fun reconstructsTheExactTargetBytes() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        val baseSha = sha(baseBytes)
        writePatch(patch, baseSha, targetBytes, targetSha, ops())
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            output = output,
            manifest = manifest(baseSha, targetSha, targetBytes, patch.length()),
        )
        assertTrue("expected success, got $result", result is DeltaApplyResult.Success)
        assertEquals(targetSha, (result as DeltaApplyResult.Success).targetSha256)
        assertArrayEquals(targetBytes, output.readBytes())
    }

    @Test
    fun refusesAChangedBaseAndPublishesNothing() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        writePatch(patch, sha(baseBytes), targetBytes, targetSha, ops())
        base.writeBytes(ByteArray(baseBytes.size) { 1 })
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            output = output,
            manifest = manifest(sha(baseBytes), targetSha, targetBytes, patch.length()),
        )
        assertEquals(DeltaApplyFailure.BASE_MISMATCH, (result as DeltaApplyResult.Failure).reason)
        assertFalse("no output may survive a rejected base", output.exists())
    }

    @Test
    fun refusesATruncatedPatchAndPublishesNothing() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        val baseSha = sha(baseBytes)
        writePatch(patch, baseSha, targetBytes, targetSha, ops())
        val truncated = patch.readBytes().copyOf(patch.length().toInt() - 40)
        patch.writeBytes(truncated)
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            output = output,
            manifest = manifest(baseSha, targetSha, targetBytes, patch.length()),
        )
        assertEquals(DeltaApplyFailure.PATCH_TRUNCATED, (result as DeltaApplyResult.Failure).reason)
        assertFalse(output.exists())
    }

    @Test
    fun refusesAWrongTargetHashAndPublishesNothing() = withFiles { base, patch, output ->
        val targetBytes = target()
        val baseSha = sha(baseBytes)
        writePatch(patch, baseSha, targetBytes, sha(targetBytes), ops())
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            output = output,
            manifest = manifest(baseSha, "9".repeat(64), targetBytes, patch.length()),
        )
        assertEquals(DeltaApplyFailure.BAD_HEADER, (result as DeltaApplyResult.Failure).reason)
        assertFalse(output.exists())
    }

    @Test
    fun refusesInconsistentHeaderTotals() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        val baseSha = sha(baseBytes)
        writePatch(patch, baseSha, targetBytes, targetSha, ops(), declareCopyBytes = 20_000L, declareInsertBytes = 7_000L)
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            output = output,
            manifest = manifest(baseSha, targetSha, targetBytes, patch.length()),
        )
        assertEquals(DeltaApplyFailure.BAD_HEADER, (result as DeltaApplyResult.Failure).reason)
        assertFalse(output.exists())
    }

    @Test
    fun refusesOutOfBoundsCopy() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        val baseSha = sha(baseBytes)
        val brokenOps = listOf(
            Op(copy = true, offset = baseBytes.size - 100L, length = 10_000L),
        ) + ops().drop(1)
        writePatch(patch, baseSha, targetBytes, targetSha, brokenOps)
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            output = output,
            manifest = manifest(baseSha, targetSha, targetBytes, patch.length()),
        )
        assertEquals(DeltaApplyFailure.OP_INVALID, (result as DeltaApplyResult.Failure).reason)
        assertFalse(output.exists())
    }

    @Test
    fun cancellationDeletesThePartialOutput() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        val baseSha = sha(baseBytes)
        writePatch(patch, baseSha, targetBytes, targetSha, ops())
        var reads = 0
        val result = FloePatchApplier(bufferBytes = 1024).apply(
            base = base,
            patch = patch,
            output = output,
            manifest = manifest(baseSha, targetSha, targetBytes, patch.length()),
            checkCancelled = { reads++ > 2 },
        )
        assertEquals(DeltaApplyResult.Cancelled, result)
        assertFalse(output.exists())
    }

    @Test
    fun refusesOutputAliasingBaseAndPreservesBothInputs() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        val baseSha = sha(baseBytes)
        writePatch(patch, baseSha, targetBytes, targetSha, ops())
        val baseBefore = base.readBytes()
        val patchBefore = patch.readBytes()
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            // The caller must not be able to turn the applier into a shredder
            // for its own base file.
            output = base,
            manifest = manifest(baseSha, targetSha, targetBytes, patch.length()),
        )
        assertEquals(DeltaApplyFailure.ALIASED_INPUT, (result as DeltaApplyResult.Failure).reason)
        assertTrue("base must remain", base.isFile)
        assertArrayEquals("base bytes must be untouched", baseBefore, base.readBytes())
        assertArrayEquals("patch bytes must be untouched", patchBefore, patch.readBytes())
    }

    @Test
    fun refusesOutputAliasingPatchAndPreservesIt() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        val baseSha = sha(baseBytes)
        writePatch(patch, baseSha, targetBytes, targetSha, ops())
        val patchBefore = patch.readBytes()
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            output = patch,
            manifest = manifest(baseSha, targetSha, targetBytes, patch.length()),
        )
        assertEquals(DeltaApplyFailure.ALIASED_INPUT, (result as DeltaApplyResult.Failure).reason)
        assertTrue("patch must remain", patch.isFile)
        assertArrayEquals("patch bytes must be untouched", patchBefore, patch.readBytes())
    }

    @Test
    fun refusesBaseAliasingPatchAndPreservesTheFile() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        // One file used as both protected inputs: the applier must refuse
        // before it can hash/parse or delete anything.
        base.copyTo(patch, overwrite = true)
        val before = patch.readBytes()
        val result = FloePatchApplier().apply(
            base = patch,
            patch = patch,
            output = output,
            manifest = manifest(sha(before), targetSha, targetBytes, before.size.toLong()),
        )
        assertEquals(DeltaApplyFailure.ALIASED_INPUT, (result as DeltaApplyResult.Failure).reason)
        assertTrue(patch.isFile)
        assertArrayEquals(before, patch.readBytes())
        assertFalse("no output may be created for an aliased invocation", output.exists())
    }

    @Test
    fun refusesASymlinkOutputPointingAtTheBase() {
        val dir = Files.createTempDirectory("floe-delta-alias-").toFile()
        try {
            val base = File(dir, "base.apk").apply { writeBytes(baseBytes) }
            val patch = File(dir, "patch.delta")
            val targetBytes = target()
            val targetSha = sha(targetBytes)
            val baseSha = sha(baseBytes)
            writePatch(patch, baseSha, targetBytes, targetSha, ops())
            val link = Paths.get(dir.absolutePath, "out-link")
            Files.createSymbolicLink(link, base.toPath())
            val before = base.readBytes()
            val result = FloePatchApplier().apply(
                base = base,
                patch = patch,
                output = link.toFile(),
                manifest = manifest(baseSha, targetSha, targetBytes, patch.length()),
            )
            assertEquals(DeltaApplyFailure.ALIASED_INPUT, (result as DeltaApplyResult.Failure).reason)
            assertTrue(Files.isSymbolicLink(link))
            assertArrayEquals(before, base.readBytes())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun patchSizeMustMatchTheManifest() = withFiles { base, patch, output ->
        val targetBytes = target()
        val targetSha = sha(targetBytes)
        val baseSha = sha(baseBytes)
        writePatch(patch, baseSha, targetBytes, targetSha, ops())
        val result = FloePatchApplier().apply(
            base = base,
            patch = patch,
            output = output,
            manifest = manifest(baseSha, targetSha, targetBytes, patch.length() + 1),
        )
        assertEquals(DeltaApplyFailure.PATCH_SIZE_MISMATCH, (result as DeltaApplyResult.Failure).reason)
        assertFalse(output.exists())
    }
}
