// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import com.floe.android.core.workbenchmedia.snapshot.ProjectSnapshotParser
import com.floe.android.core.workbenchmedia.snapshot.VerifiedSnapshot
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.feature.workbench.ImageCopySelection
import com.floe.android.feature.workbench.ImageExportSettings
import com.floe.android.feature.workbench.RenderSnapshotLease
import java.io.File
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Source-authored C03 model-copy purpose checks (NOT RUN in this lane).
 *
 * The pixel-level order/equivalence check needs the real Android
 * Bitmap/Canvas renderer and stays a Main/instrumented or device gate. These
 * tests cover the closed typed ticket contract that selects that renderer:
 * only an exact full-canvas PNG of an existing, visible source layer with a
 * shaped project selection may enter the post-composite copy path, and a
 * non-identity whole-canvas adjustment is not a reason to refuse it.
 */
class C03ImageCopySelectionTest {
    @Test
    fun copyPurposeAcceptsNonIdentityCanvasAdjustmentAtFullCanvasPng() {
        val snapshot = snapshot()
        val settings = ImageExportSettings(
            format = "png",
            fileName = "c03-copy-test",
        )
        val (width, height) = ImageExporter.validate(
            snapshot,
            settings,
            ImageCopySelection(SOURCE_LAYER_ID),
        )
        assertEquals(48, width)
        assertEquals(32, height)
    }

    @Test
    fun copyPurposeRefusesNonPngScaledMissingLayerAndUnshapedRequests() {
        val snapshot = snapshot()
        assertRefused {
            ImageExporter.validate(
                snapshot,
                ImageExportSettings(format = "jpeg", fileName = "copy"),
                ImageCopySelection(SOURCE_LAYER_ID),
            )
        }
        // The purpose is PNG-only and must fail before any HEIC/JPEG encoder
        // probe, so this is safe in the pure-JVM unit test.
        assertRefused {
            ImageExporter.validate(
                snapshot,
                ImageExportSettings(format = "heic", fileName = "copy"),
                ImageCopySelection(SOURCE_LAYER_ID),
            )
        }
        assertRefused {
            ImageExporter.validate(
                snapshot,
                ImageExportSettings(format = "png", width = 24, height = 16, fileName = "copy"),
                ImageCopySelection(SOURCE_LAYER_ID),
            )
        }
        assertRefused {
            ImageExporter.validate(
                snapshot,
                ImageExportSettings(format = "png", fileName = "copy"),
                ImageCopySelection("99999999-9999-4999-8999-999999999999"),
            )
        }
        assertRefused {
            ImageExporter.validate(
                snapshot(selection = false),
                ImageExportSettings(format = "png", fileName = "copy"),
                ImageCopySelection(SOURCE_LAYER_ID),
            )
        }
        assertRefused {
            ImageExporter.validate(
                snapshot(shapes = emptyList()),
                ImageExportSettings(format = "png", fileName = "copy"),
                ImageCopySelection(SOURCE_LAYER_ID),
            )
        }
        assertRefused {
            ImageExporter.validate(
                snapshot(hidden = true),
                ImageExportSettings(format = "png", fileName = "copy"),
                ImageCopySelection(SOURCE_LAYER_ID),
            )
        }
    }

    @Test
    fun ordinaryPngExportStillRendersTheWholeProjectWithoutACopyPurpose() {
        val snapshot = snapshot()
        val (width, height) = ImageExporter.validate(
            snapshot,
            ImageExportSettings(format = "png", fileName = "export"),
        )
        assertEquals(48, width)
        assertEquals(32, height)
    }

    private fun assertRefused(block: () -> Unit) {
        assertThrows(MediaRefusal::class.java) { block() }
    }

    private fun snapshot(
        selection: Boolean = true,
        shapes: List<String> = listOf(RECTANGLE_SHAPE),
        hidden: Boolean = false,
    ): VerifiedSnapshot {
        val root = createTempDirectory("c03-copy-purpose").toFile()
        val selectionJson = if (selection) {
            ""","imageSelection":{"shapes":[${shapes.joinToString(",")}],"feather":0.0,"inverted":false}"""
        } else {
            ""
        }
        val json = """
            {"schemaVersion":1,
             "id":"$PROJECT_ID",
             "kind":"image",
             "revision":7,
             "canvas":{"width":48,"height":32},
             "assets":[],
             "imageLayers":[{
               "id":"$SOURCE_LAYER_ID",
               "kind":"fill",
               "name":"Base",
               "fillColorHex":"#3366FF",
               "opacity":0.9,
               "isHidden":$hidden
             }],
             "canvasAdjustment":{"saturation":1.35,"blurRadius":2.5,"temperature":7200.0}
             $selectionJson}
        """.trimIndent()
        val projection = ProjectSnapshotParser.parse(json)
        val bytes = json.toByteArray(Charsets.UTF_8)
        val file = File(root, "snapshot.json")
        file.writeBytes(bytes)
        return VerifiedSnapshot(
            root = root,
            file = file,
            lease = RenderSnapshotLease(
                leaseID = "lease-c03-copy",
                mediaRootPath = root.path,
                relativePath = "snapshot.json",
                sha256 = "0".repeat(64),
                byteCount = bytes.size.toLong(),
                expiresAt = "2099-01-01T00:00:00Z",
            ),
            projection = projection,
        )
    }

    private companion object {
        const val PROJECT_ID = "11111111-1111-4111-8111-111111111111"
        const val SOURCE_LAYER_ID = "22222222-2222-4222-8222-222222222222"
        const val RECTANGLE_SHAPE =
            """{"kind":"rectangle","operation":"replace","points":[{"x":0.1,"y":0.1},{"x":0.6,"y":0.6}]}"""
    }
}
