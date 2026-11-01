// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.WorkbenchR2Limits
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaWorkspaceStagerTest {
    private val owner = MediaWorkspaceOwner(
        taskID = UUID.randomUUID().toString(),
        workspaceID = UUID.randomUUID().toString(),
        nativeEpoch = 7,
        hostGeneration = 3,
    )

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private class FakeChannel(
        val logicalPath: String,
        val payload: ByteArray,
        val declaredBytes: Long = payload.size.toLong(),
        val sha: String,
        val mode: String = "export-media",
        val extraAtEof: Boolean = false,
        val closeStatus: Int = 0,
        val openStatus: Long = 41L,
        val openFailure: Throwable? = null,
        val onRead: (Long) -> Unit = {},
    ) : MediaWorkspaceSourceChannel {
        var opened = 0
        var closed = 0
        var reads = 0
        var lastOwner: MediaWorkspaceOwner? = null
        var lastKind: String? = null

        override fun open(owner: MediaWorkspaceOwner, logicalPath: String, kind: String): Long {
            opened += 1
            lastOwner = owner
            lastKind = kind
            openFailure?.let { throw it }
            return openStatus
        }

        override fun info(ticket: Long, reply: ByteArray): Int {
            val json = """
                {"ok":1,"mode":"$mode","sha256":"$sha","bytes":$declaredBytes,
                 "logicalPath":"${this.logicalPath}","recoveryID":"recovery-1",
                 "sourceID":"source-1","sourceRevision":"revision-1"}
            """.trimIndent()
            val bytes = json.toByteArray(Charsets.UTF_8)
            bytes.copyInto(reply, 0, 0, bytes.size)
            return bytes.size
        }

        override fun read(ticket: Long, offset: Long, target: ByteArray): Int {
            reads += 1
            onRead(offset)
            if (offset == declaredBytes) {
                if (extraAtEof) {
                    target[0] = 9
                    return 1
                }
                return 0
            }
            if (offset > declaredBytes) return 0
            val available = (declaredBytes - offset).coerceAtMost(target.size.toLong()).toInt()
            if (available <= 0) return 0
            val count = minOf(available, payload.size - offset.toInt())
            if (count <= 0) return 0
            payload.copyInto(target, 0, offset.toInt(), offset.toInt() + count)
            return count
        }

        override fun close(ticket: Long): Int {
            closed += 1
            return closeStatus
        }
    }

    private fun failure(block: () -> Unit): CreativeException {
        try {
            block()
        } catch (error: CreativeException) {
            return error
        }
        throw AssertionError("expected CreativeException")
    }

    @Test
    fun streamsExactBytesHashAndOwnedMetadata() {
        val stagingRoot = Files.createTempDirectory("floe-media-workspace").toFile()
        try {
            val payload = ByteArray(200_000) { (it % 251).toByte() }
            val digest = sha256(payload)
            val channel = FakeChannel(
                logicalPath = "Notes/clip.mp4",
                payload = payload,
                sha = digest,
            )
            val stager = MediaWorkspaceStager(stagingRoot, channel)
            var ownerChecks = 0
            val staged = stager.stage(
                owner = owner,
                relativePath = "Notes/clip.mp4",
                kind = "video",
                isCurrent = {
                    ownerChecks += 1
                    true
                },
            )
            assertEquals(digest, staged.sha256)
            assertEquals(payload.size.toLong(), staged.byteCount)
            assertEquals("clip.mp4", staged.displayName)
            assertEquals("Notes/clip.mp4", staged.logicalPath)
            assertEquals("source-1", staged.sourceID)
            assertEquals("revision-1", staged.sourceRevision)
            assertTrue(staged.file.isFile)
            assertTrue(payload.contentEquals(staged.file.readBytes()))
            assertEquals(1, channel.opened)
            assertEquals(1, channel.closed)
            assertEquals(owner, channel.lastOwner)
            assertEquals("video", channel.lastKind)
            assertTrue(ownerChecks >= 3)
            assertFalse(staged.file.parentFile!!.listFiles()!!.any { it.name.endsWith(".part") })
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun refusesAboveMediaPolicyBeforeAnyRead() {
        val stagingRoot = Files.createTempDirectory("floe-media-cap").toFile()
        try {
            val channel = FakeChannel(
                logicalPath = "Notes/huge.png",
                payload = ByteArray(0),
                declaredBytes = WorkbenchR2Limits.IMPORT_IMAGE_BYTES + 1,
                sha = "a".repeat(64),
            )
            val error = failure {
                MediaWorkspaceStager(stagingRoot, channel).stage(
                    owner = owner,
                    relativePath = "Notes/huge.png",
                    kind = "image",
                    isCurrent = { true },
                )
            }
            assertEquals("importTooLarge", error.code)
            assertEquals("workspaceSourceTooLarge", error.reason)
            assertEquals(0, channel.reads)
            assertEquals(1, channel.closed)
            assertTrue(stagingRoot.listFiles().orEmpty().isEmpty())
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun refusesAboveVideoCeilingBeforeAnyRead() {
        val stagingRoot = Files.createTempDirectory("floe-media-native-cap").toFile()
        try {
            // 8 GiB + 1 declared by the native header: the per-kind policy cap
            // refuses before a single chunk, and the absolute channel ceiling
            // is exactly the video policy cap (not the old 1 GiB snapshot).
            val channel = FakeChannel(
                logicalPath = "Notes/huge.mp4",
                payload = ByteArray(0),
                declaredBytes = MediaWorkspaceStagingPolicy.NATIVE_EGRESS_MAX_BYTES + 1,
                sha = "b".repeat(64),
            )
            val error = failure {
                MediaWorkspaceStager(stagingRoot, channel).stage(
                    owner = owner,
                    relativePath = "Notes/huge.mp4",
                    kind = "video",
                    isCurrent = { true },
                )
            }
            assertEquals("importTooLarge", error.code)
            assertEquals("workspaceSourceTooLarge", error.reason)
            assertEquals(0, channel.reads)
            assertEquals(1, channel.closed)
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun mediaChannelCeilingsMatchTheClosedNativeLane() {
        assertEquals(8L shl 30, MediaWorkspaceStagingPolicy.NATIVE_EGRESS_MAX_BYTES)
        assertEquals(128L * 1024 * 1024, WorkbenchR2Limits.IMPORT_IMAGE_BYTES)
        assertEquals(1L shl 30, WorkbenchR2Limits.IMPORT_AUDIO_BYTES)
        assertEquals(8L shl 30, WorkbenchR2Limits.IMPORT_VIDEO_BYTES)
        assertEquals(
            WorkbenchR2Limits.IMPORT_VIDEO_BYTES,
            MediaWorkspaceStagingPolicy.NATIVE_EGRESS_MAX_BYTES,
        )
        // Byte-aligned with the native `G04WorkspaceMediaKind` closed sets.
        assertEquals(
            setOf("png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif"),
            MediaWorkspaceStagingPolicy.extensions("image"),
        )
        assertEquals(
            setOf("mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"),
            MediaWorkspaceStagingPolicy.extensions("audio"),
        )
        assertEquals(setOf("mp4", "mov", "m4v"), MediaWorkspaceStagingPolicy.extensions("video"))
        assertEquals(null, MediaWorkspaceStagingPolicy.extensions("document"))
    }

    @Test
    fun oldCoreWithoutTheMediaSymbolIsTypedUnavailable() {
        val stagingRoot = Files.createTempDirectory("floe-media-old-core").toFile()
        try {
            val channel = FakeChannel(
                logicalPath = "Notes/clip.mp4",
                payload = ByteArray(0),
                sha = "e".repeat(64),
                openFailure = UnsatisfiedLinkError("no egressOpenMedia"),
            )
            val error = failure {
                MediaWorkspaceStager(stagingRoot, channel).stage(
                    owner = owner,
                    relativePath = "Notes/clip.mp4",
                    kind = "video",
                    isCurrent = { true },
                )
            }
            assertEquals("assetStagingUnavailable", error.code)
            assertEquals("workspaceSourceUnavailable", error.reason)
            assertTrue(error.retryable)
            assertEquals(0, channel.reads)
            assertEquals(0, channel.closed)
            assertTrue(stagingRoot.listFiles().orEmpty().isEmpty())
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun nativeMediaOpenRefusalsMapToTypedReasons() {
        val stagingRoot = Files.createTempDirectory("floe-media-open-status").toFile()
        try {
            fun stageWith(status: Long): CreativeException = failure {
                MediaWorkspaceStager(
                    stagingRoot,
                    FakeChannel(
                        logicalPath = "Notes/clip.mp4",
                        payload = ByteArray(0),
                        sha = "f".repeat(64),
                        openStatus = status,
                    ),
                ).stage(
                    owner = owner,
                    relativePath = "Notes/clip.mp4",
                    kind = "video",
                    isCurrent = { true },
                )
            }
            val tooLarge = stageWith(-509L)
            assertEquals("importTooLarge", tooLarge.code)
            assertEquals("workspaceSourceTooLarge", tooLarge.reason)
            val disk = stageWith(-511L)
            assertEquals("insufficientStorage", disk.code)
            assertEquals("workspaceStagingNoSpace", disk.reason)
            val stale = stageWith(-502L)
            assertEquals("staleGeneration", stale.code)
            assertEquals("workspaceSourceOwnerChanged", stale.reason)
            val identity = stageWith(-505L)
            assertEquals("staleGeneration", identity.code)
            assertEquals("workspaceSourceOwnerChanged", identity.reason)
            val timeout = stageWith(-518L)
            assertEquals("assetStagingUnavailable", timeout.code)
            assertTrue(timeout.retryable)
            assertTrue(stagingRoot.listFiles().orEmpty().isEmpty())
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun infoMustComeFromTheClosedMediaChannel() {
        val stagingRoot = Files.createTempDirectory("floe-media-mode").toFile()
        try {
            val channel = FakeChannel(
                logicalPath = "Notes/clip.mp4",
                payload = ByteArray(16),
                sha = "a".repeat(64),
                mode = "export",
            )
            val error = failure {
                MediaWorkspaceStager(stagingRoot, channel).stage(
                    owner = owner,
                    relativePath = "Notes/clip.mp4",
                    kind = "video",
                    isCurrent = { true },
                )
            }
            assertEquals("assetStagingInvalid", error.code)
            assertEquals("workspaceSourceInfoMismatch", error.reason)
            assertEquals(0, channel.reads)
            assertEquals(1, channel.closed)
            assertTrue(stagingRoot.listFiles().orEmpty().isEmpty())
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun earlyEofAndExtraEofAreBothRefusedAndOnlyOwnedStageIsDeleted() {
        val stagingRoot = Files.createTempDirectory("floe-media-eof").toFile()
        try {
            val payload = ByteArray(4096) { 1 }
            val short = FakeChannel(
                logicalPath = "Notes/a.png",
                payload = payload,
                declaredBytes = payload.size.toLong() + 10,
                sha = "c".repeat(64),
            )
            val shortError = failure {
                MediaWorkspaceStager(stagingRoot, short).stage(
                    owner = owner,
                    relativePath = "Notes/a.png",
                    kind = "image",
                    isCurrent = { true },
                )
            }
            assertEquals("assetStagingInvalid", shortError.code)

            val extra = FakeChannel(
                logicalPath = "Notes/a.png",
                payload = payload,
                sha = sha256(payload),
                extraAtEof = true,
            )
            val extraError = failure {
                MediaWorkspaceStager(stagingRoot, extra).stage(
                    owner = owner,
                    relativePath = "Notes/a.png",
                    kind = "image",
                    isCurrent = { true },
                )
            }
            assertEquals("assetStagingInvalid", extraError.code)
            assertEquals("workspaceSourceLengthMismatch", extraError.reason)
            assertTrue(stagingRoot.listFiles().orEmpty().isEmpty())
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun ownerChangeClosesTicketAndDeletesOnlyOwnedStage() {
        val stagingRoot = Files.createTempDirectory("floe-media-owner").toFile()
        try {
            val payload = ByteArray(300_000) { 2 }
            val channel = FakeChannel(
                logicalPath = "Notes/b.mp4",
                payload = payload,
                sha = sha256(payload),
                onRead = { },
            )
            var alive = true
            val error = failure {
                MediaWorkspaceStager(stagingRoot, channel).stage(
                    owner = owner,
                    relativePath = "Notes/b.mp4",
                    kind = "video",
                    isCurrent = {
                        val value = alive
                        alive = false
                        value
                    },
                )
            }
            assertEquals("staleGeneration", error.code)
            assertEquals(1, channel.closed)
            assertTrue(stagingRoot.listFiles().orEmpty().isEmpty())
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun traversalAndForeignExtensionAreRefusedBeforeOpen() {
        val stagingRoot = Files.createTempDirectory("floe-media-path").toFile()
        try {
            val channel = FakeChannel(
                logicalPath = "Notes/x.png",
                payload = ByteArray(1),
                sha = "d".repeat(64),
            )
            val stager = MediaWorkspaceStager(stagingRoot, channel)
            val traversal = failure {
                stager.stage(owner, "../x.png", "image", isCurrent = { true })
            }
            assertEquals("invalidRequest", traversal.code)
            val absolute = failure {
                stager.stage(owner, "/Notes/x.png", "image", isCurrent = { true })
            }
            assertEquals("invalidRequest", absolute.code)
            val wrongFormat = failure {
                stager.stage(owner, "Notes/x.exe", "image", isCurrent = { true })
            }
            assertEquals("unsupportedSourceFormat", wrongFormat.code)
            val unknownKind = failure {
                stager.stage(owner, "Notes/x.png", "pdf", isCurrent = { true })
            }
            assertEquals("invalidRequest", unknownKind.code)
            assertEquals(0, channel.opened)
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun failedTicketCloseNeverReportsAStagedResult() {
        val stagingRoot = Files.createTempDirectory("floe-media-close").toFile()
        try {
            val payload = ByteArray(2048) { 5 }
            val channel = FakeChannel(
                logicalPath = "Notes/c.png",
                payload = payload,
                sha = sha256(payload),
                closeStatus = -514,
            )
            val error = failure {
                MediaWorkspaceStager(stagingRoot, channel).stage(
                    owner = owner,
                    relativePath = "Notes/c.png",
                    kind = "image",
                    isCurrent = { true },
                )
            }
            assertEquals("assetStagingUnavailable", error.code)
            assertEquals(1, channel.closed)
            assertTrue(stagingRoot.listFiles().orEmpty().isEmpty())
        } finally {
            stagingRoot.deleteRecursively()
        }
    }

    @Test
    fun mediaPolicyMatchesReviewedLargeImportCeilingsAndDiskRule() {
        assertEquals(
            WorkbenchR2Limits.IMPORT_IMAGE_BYTES,
            MediaWorkspaceStagingPolicy.maxBytes("image") ?: -1L,
        )
        assertEquals(
            WorkbenchR2Limits.IMPORT_AUDIO_BYTES,
            MediaWorkspaceStagingPolicy.maxBytes("audio") ?: -1L,
        )
        assertEquals(
            WorkbenchR2Limits.IMPORT_VIDEO_BYTES,
            MediaWorkspaceStagingPolicy.maxBytes("video") ?: -1L,
        )
        assertEquals(null, MediaWorkspaceStagingPolicy.maxBytes("document"))
        assertTrue(MediaWorkspaceStagingPolicy.hasFreeSpace(0L, 10L))
        assertTrue(MediaWorkspaceStagingPolicy.hasFreeSpace(10L, 10L))
        assertFalse(MediaWorkspaceStagingPolicy.hasFreeSpace(9L, 10L))
        assertTrue(MediaWorkspaceStagingPolicy.requiredFreeBytes(1024L) >= 1024L)
    }
}
