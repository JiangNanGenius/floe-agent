// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.snapshot.ProjectSnapshotParser
import com.floe.android.core.workbenchmedia.snapshot.SnapshotExpectation
import com.floe.android.core.workbenchmedia.snapshot.SnapshotVerifier
import com.floe.android.core.workbenchmedia.util.Digests
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.feature.workbench.RenderSnapshotLease
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SnapshotValidationTest {
    // A real post-2030 wall clock: the valid lease (2030-01-01) is still in
    // the future while the expired-lease case (2000-01-01) is genuinely past.
    private val clock = MediaClock { 1_800_000_000_000L }
    private val tempRoot: File = Files.createTempDirectory("workbenchmedia-snapshot").toFile()

    @After
    fun cleanup() {
        tempRoot.deleteRecursively()
    }

    private fun projectJson(
        projectID: String = "project-1",
        revision: Long = 3,
        extraLayer: String = "",
    ): String = """
        {
          "schemaVersion": 1,
          "id": "$projectID",
          "kind": "image",
          "name": "Test project",
          "createdAt": "2026-11-01T00:00:00Z",
          "updatedAt": "2026-11-01T00:00:00Z",
          "revision": $revision,
          "canvas": { "width": 100, "height": 100 },
          "assets": [],
          "imageLayers": [ $extraLayer ],
          "videoTimeline": { "clips": [], "music": [], "captions": [] }
        }
    """.trimIndent()

    private fun writeSnapshot(json: String): Pair<File, RenderSnapshotLease> {
        val file = File(tempRoot, "project.json")
        file.writeText(json)
        val digest = Digests.sha256(file, 8L * 1024L * 1024L)!!
        return file to RenderSnapshotLease(
            leaseID = "lease-1",
            mediaRootPath = tempRoot.path,
            relativePath = "project.json",
            sha256 = digest,
            byteCount = file.length(),
            expiresAt = "2030-01-01T00:00:00Z",
        )
    }

    @Test
    fun validLeaseProjectRevisionAndDigestPass() {
        val (_, lease) = writeSnapshot(projectJson())
        val verified = SnapshotVerifier.verify(
            SnapshotExpectation(1L, "project-1", 3L, "timeline-digest", tempRoot.path, "attempt-1", lease),
            AuthorityGrant(1L, tempRoot.path, "project-1", 3L, "timeline-digest"),
            clock,
        )
        assertEquals("project-1", verified.projection.project.id)
        assertEquals(3L, verified.projection.project.revision)
    }

    @Test
    fun digestMismatchIsRefused() {
        val (file, lease) = writeSnapshot(projectJson())
        file.writeText(projectJson(revision = 4))
        assertRefusal("renderUnsupported") {
            SnapshotVerifier.verify(
                SnapshotExpectation(1L, "project-1", 3L, "timeline-digest", tempRoot.path, "attempt-1", lease),
                AuthorityGrant(1L, tempRoot.path, "project-1", 3L, "timeline-digest"),
                clock,
            )
        }
    }

    @Test
    fun revisionMismatchIsRefused() {
        val (_, lease) = writeSnapshot(projectJson(revision = 4))
        assertRefusal("renderUnsupported") {
            SnapshotVerifier.verify(
                SnapshotExpectation(1L, "project-1", 3L, "timeline-digest", tempRoot.path, "attempt-1", lease),
                AuthorityGrant(1L, tempRoot.path, "project-1", 3L, "timeline-digest"),
                clock,
            )
        }
    }

    @Test
    fun epochMismatchIsRefused() {
        val (_, lease) = writeSnapshot(projectJson())
        assertRefusal("renderUnsupported") {
            SnapshotVerifier.verify(
                SnapshotExpectation(1L, "project-1", 3L, "timeline-digest", tempRoot.path, "attempt-1", lease),
                AuthorityGrant(2L, tempRoot.path, "project-1", 3L, "timeline-digest"),
                clock,
            )
        }
    }

    @Test
    fun expiredLeaseIsRefused() {
        val (_, lease) = writeSnapshot(projectJson())
        assertRefusal("renderTicketExpired") {
            SnapshotVerifier.verify(
                SnapshotExpectation(1L, "project-1", 3L, "timeline-digest", tempRoot.path, "attempt-1",
                    lease.copy(expiresAt = "2000-01-01T00:00:00Z")),
                AuthorityGrant(1L, tempRoot.path, "project-1", 3L, "timeline-digest"),
                clock,
            )
        }
    }

    @Test
    fun traversalSnapshotPathIsRefused() {
        val (_, lease) = writeSnapshot(projectJson())
        assertRefusal("renderUnsupported") {
            SnapshotVerifier.verify(
                SnapshotExpectation(1L, "project-1", 3L, "timeline-digest", tempRoot.path, "attempt-1",
                    lease.copy(relativePath = "../project.json")),
                AuthorityGrant(1L, tempRoot.path, "project-1", 3L, "timeline-digest"),
                clock,
            )
        }
    }

    @Test
    fun unknownActiveLayerFieldIsCarriedAsAnExplicitRefusalFact() {
        val parsed = ProjectSnapshotParser.parse(
            projectJson(
                extraLayer = """{"id":"layer-1","kind":"image","name":"L","futureEffect":true}""",
            ),
        )
        assertTrue(parsed.layers.single().unknownLayerKeys.contains("futureEffect"))
    }

    @Test
    fun knownLayerFieldsAreAccepted() {
        val parsed = ProjectSnapshotParser.parse(
            projectJson(
                extraLayer = """{
                    "id":"layer-1","kind":"image","name":"L","assetID":"a",
                    "transform":{"centerX":0.5,"centerY":0.5,"scale":1,"rotationDegrees":0},
                    "opacity":1,"isHidden":false,"isLocked":false,
                    "adjustment":{"saturation":1,"filterID":"CIPhotoEffectMono"}
                }""",
            ),
        )
        assertEquals(1, parsed.layers.size)
        assertEquals("CIPhotoEffectMono", parsed.layers[0].layer.adjustment.filterID)
    }

    private fun assertRefusal(code: String, block: () -> Unit) {
        try {
            block()
            fail("Expected MediaRefusal $code")
        } catch (failure: MediaRefusal) {
            assertEquals(code, failure.code)
            assertNotNull(failure.message)
            assertTrue(failure.message.isNotBlank())
        }
    }
}
