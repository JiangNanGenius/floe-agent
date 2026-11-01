// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.ExportVerification
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportReceiptBinding
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class MediaWorkbenchExportAuthorityTest {
    private lateinit var root: java.io.File
    private lateinit var projectRoot: java.io.File
    private lateinit var otherRoot: java.io.File

    private val context = CreativeProjectContext(
        projectID = "project-1",
        sessionToken = "session-1",
        storage = CreativeStorageLayer.AppOwned,
        origin = CreativeOriginContext.standalone(),
    )

    private fun sha(fill: Char): String = fill.toString().repeat(64)

    private fun identity(
        projectID: String = "project-1",
        mediaRootPath: String = projectRoot.path,
        revision: Long = 3,
        digest: String = "digest-3",
        attemptID: String = "attempt-1",
        output: String = "Workbench/Exports/a.mp4",
        mime: String = "video/mp4",
        bytes: Long = 10,
        hash: String = sha('a'),
    ) = MediaWorkbenchReceiptIdentity(
        projectID = projectID,
        mediaRootPath = mediaRootPath,
        projectRevision = revision,
        timelineDigest = digest,
        attemptID = attemptID,
        outputRelativePath = output,
        mimeType = mime,
        byteCount = bytes,
        sha256 = hash,
    )

    private fun captured(
        context: CreativeProjectContext = this.context,
        epoch: Long = 7,
        projectID: String = "project-1",
        ownerProof: String = "durable-owner-1",
        storageKey: String = "appOwned",
        originKey: String? = "standalone",
        storage: CreativeStorageLayer = CreativeStorageLayer.AppOwned,
        rootPath: String = projectRoot.canonicalPath,
    ) = MediaWorkbenchCapturedOwner(
        context = context,
        epoch = epoch,
        projectID = projectID,
        canonicalRootPath = rootPath,
        ownerProof = ownerProof,
        storageKey = storageKey,
        originKey = originKey,
        storage = storage,
    )

    private fun resolved(
        epoch: Long = 7,
        projectID: String = "project-1",
        ownerProof: String = "durable-owner-1",
        storageKey: String = "appOwned",
        originKey: String? = "standalone",
        storage: CreativeStorageLayer = CreativeStorageLayer.AppOwned,
        rootPath: String = projectRoot.path,
    ) = MediaWorkbenchResolvedOwner(
        epoch = epoch,
        mediaRootPath = rootPath,
        projectID = projectID,
        ownerProof = ownerProof,
        storageKey = storageKey,
        originKey = originKey,
        storage = storage,
    )

    @Before
    fun setUp() {
        root = Files.createTempDirectory("floe-export-authority").toFile()
        projectRoot = java.io.File(root, "projects/project-1").apply { mkdirs() }
        otherRoot = java.io.File(root, "projects/project-2").apply { mkdirs() }
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    @Test
    fun exactCapturedOwnerAndLiveEchoGrantTheNativeRoot() {
        val decision = MediaWorkbenchExportAuthorization.authorize(
            identity = identity(),
            captured = captured(),
            resolved = resolved(),
            epochLive = true,
        )
        assertTrue(decision is MediaWorkbenchOwnerDecision.Granted)
        val granted = decision as MediaWorkbenchOwnerDecision.Granted
        assertEquals(projectRoot.canonicalPath, granted.canonicalRoot.path)
        assertEquals("durable-owner-1", granted.ownerProof)
    }

    @Test
    fun missingCaptureHasNoAcceptedBaseRootFallback() {
        val decision = MediaWorkbenchExportAuthorization.authorize(
            identity = identity(),
            captured = null,
            resolved = resolved(),
            epochLive = true,
        )
        assertTrue(decision is MediaWorkbenchOwnerDecision.Refused)
        assertEquals(
            "exportOwnerUnverified",
            (decision as MediaWorkbenchOwnerDecision.Refused).code,
        )
    }

    @Test
    fun staleEpochOrRootChangeRejectsTheOldClaim() {
        val old = captured(epoch = 7)
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity = identity(),
                captured = old,
                resolved = resolved(epoch = 8),
                epochLive = true,
            ),
            "staleGeneration",
        )
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity = identity(),
                captured = old,
                resolved = resolved(epoch = 7),
                epochLive = false,
            ),
            "staleGeneration",
        )
        // The captured object itself is immutable evidence of the admitted
        // owner; a later root change never rewrites it.
        assertEquals(7L, old.epoch)
        assertEquals("durable-owner-1", old.ownerProof)
    }

    @Test
    fun foreignOwnerProofStorageOriginOrProjectIsRefused() {
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity(),
                captured(),
                resolved(ownerProof = "foreign-owner"),
                true,
            ),
            "crossOwnerRefused",
        )
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity(),
                captured(),
                resolved(storageKey = "workspace:other"),
                true,
            ),
            "crossOwnerRefused",
        )
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity(),
                captured(),
                resolved(originKey = null),
                true,
            ),
            "crossOwnerRefused",
        )
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity(),
                captured(),
                resolved(projectID = "project-2"),
                true,
            ),
            "crossOwnerRefused",
        )
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity(),
                captured(),
                resolved(storage = CreativeStorageLayer.Workspace("workspace-1")),
                true,
            ),
            "crossOwnerRefused",
        )
    }

    @Test
    fun capturedOwnerForAnotherProjectCannotAuthorizeThisReceipt() {
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity(),
                captured(projectID = "project-2", rootPath = otherRoot.path),
                resolved(projectID = "project-2", rootPath = otherRoot.path),
                true,
            ),
            "crossOwnerRefused",
        )
    }

    @Test
    fun receiptRootCanNeverWidenTheNativeRoot() {
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity(mediaRootPath = otherRoot.path),
                captured(),
                resolved(),
                true,
            ),
            "crossOwnerRefused",
        )
        assertRefused(
            MediaWorkbenchExportAuthorization.authorize(
                identity(),
                captured(),
                resolved(rootPath = otherRoot.path),
                true,
            ),
            "crossOwnerRefused",
        )
    }

    @Test
    fun registryKeysTheFullReceiptIdentityNotAnAttemptCollision() {
        val registry = MediaWorkbenchReceiptRegistry()
        val first = identity(output = "Workbench/Exports/a.mp4", hash = sha('a'))
        val second = identity(output = "Workbench/Exports/b.mp4", hash = sha('b'))
        assertEquals(first.attemptID, second.attemptID)
        registry.remember(first, captured())
        assertEquals("durable-owner-1", registry.lookup(first)?.ownerProof)
        assertNull(registry.lookup(second))
        assertEquals(1, registry.size())
    }

    @Test
    fun reopenedSameOwnerRefreshesTheSessionButForeignProofNeverOverwrites() {
        val registry = MediaWorkbenchReceiptRegistry()
        val receipt = identity()
        registry.remember(receipt, captured())
        val reopened = captured(context = context.copy(sessionToken = "session-2"))
        registry.remember(receipt, reopened)
        assertEquals("session-2", registry.lookup(receipt)?.context?.sessionToken)
        registry.remember(receipt, captured(ownerProof = "foreign-owner"))
        assertEquals("durable-owner-1", registry.lookup(receipt)?.ownerProof)
    }

    @Test
    fun preparedCaptureMatchesEveryBindingFieldNotJustAttempt() {
        val prepared = MediaWorkbenchPreparedCapture(
            owner = captured(),
            projectRevision = 3,
            timelineDigest = "digest-3",
            attemptID = "attempt-1",
        )
        assertTrue(prepared.matches(identity()))
        assertFalse(prepared.matches(identity(revision = 4)))
        assertFalse(prepared.matches(identity(digest = "digest-4")))
        assertFalse(prepared.matches(identity(attemptID = "attempt-2")))
        assertFalse(prepared.matches(identity(projectID = "project-2")))
        assertFalse(prepared.matches(identity(mediaRootPath = otherRoot.path)))
    }

    @Test
    fun receiptIdentityRejectsUnsafeOrMalformedIdentity() {
        val valid = receipt()
        assertTrue(MediaWorkbenchReceiptIdentity.of(valid) != null)
        assertNull(MediaWorkbenchReceiptIdentity.of(valid.copy(
            outputRelativePath = "../escape.mp4")))
        assertNull(MediaWorkbenchReceiptIdentity.of(valid.copy(sha256 = "not-a-digest")))
        assertNull(MediaWorkbenchReceiptIdentity.of(valid.copy(mimeType = "video/*")))
        assertNull(MediaWorkbenchReceiptIdentity.of(valid.copy(
            binding = valid.binding.copy(attemptID = "../attempt"))))
        assertNull(MediaWorkbenchReceiptIdentity.of(valid.copy(byteCount = 0)))
        assertNull(MediaWorkbenchReceiptIdentity.of(valid.copy(
            binding = valid.binding.copy(mediaRootPath = "relative/root"))))
    }

    private fun receipt() = MediaExportReceipt(
        binding = MediaExportReceiptBinding(
            projectID = "project-1",
            mediaRootPath = projectRoot.path,
            projectRevision = 3,
            timelineDigest = "digest-3",
            attemptID = "attempt-1",
        ),
        kind = MediaExportKind.VIDEO,
        outputRelativePath = "Workbench/Exports/a.mp4",
        mimeType = "video/mp4",
        byteCount = 10,
        sha256 = sha('a'),
        verification = ExportVerification(
            playable = true,
            decodedDurationSeconds = 3.0,
            width = 1920,
            height = 1080,
            audioTrackCount = 1,
            container = "mp4",
            codec = "video/avc",
        ),
        completedAt = "2026-11-01T00:00:00Z",
    )

    private fun assertRefused(
        decision: MediaWorkbenchOwnerDecision,
        code: String,
    ) {
        assertTrue(decision is MediaWorkbenchOwnerDecision.Refused)
        assertEquals(code, (decision as MediaWorkbenchOwnerDecision.Refused).code)
    }
}
