// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.ui.presentation.CanvasAssetPaths
import java.nio.file.Files
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CanvasAssetPathsTest {
    @Test
    fun stripsExactlyOneMaterialsPrefix() {
        val root = Files.createTempDirectory("floe-canvas-assets").toFile()
        try {
            val materials = java.io.File(root, "Materials")
            materials.mkdirs()
            java.io.File(materials, "image.png").writeBytes(byteArrayOf(1, 2, 3))
            val reference = CanvasAssetReference(
                id = "asset-1",
                localRelativePath = "Materials/image.png",
            )
            val resolved = CanvasAssetPaths.resolve(materials.path, reference)
            assertNotNull(resolved)
            assertTrue(java.io.File(requireNotNull(resolved)).isFile)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun refusesEscapingPath() {
        val root = Files.createTempDirectory("floe-canvas-assets").toFile()
        try {
            val reference = CanvasAssetReference(
                id = "asset-1",
                localRelativePath = "../outside.png",
            )
            assertNull(CanvasAssetPaths.resolve(root.path, reference))
            assertNull(CanvasAssetPaths.resolve(root.path, reference.copy(localRelativePath = "/etc/passwd")))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun missingFileIsNotAPreview() {
        val root = Files.createTempDirectory("floe-canvas-assets").toFile()
        try {
            val reference = CanvasAssetReference(
                id = "asset-1",
                localRelativePath = "Materials/missing.png",
            )
            assertNull(CanvasAssetPaths.resolve(root.path, reference))
        } finally {
            root.deleteRecursively()
        }
    }
}
