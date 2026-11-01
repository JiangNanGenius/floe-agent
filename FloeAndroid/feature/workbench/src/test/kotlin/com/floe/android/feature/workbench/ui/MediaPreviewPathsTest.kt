// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import com.floe.android.feature.workbench.ui.presentation.MediaPreviewPaths
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaPreviewPathsTest {
    @Test
    fun resolvesContainedProjectAsset() {
        val root = Files.createTempDirectory("floe-workbench").toFile()
        try {
            val assets = File(root, "Workbench/Assets")
            assets.mkdirs()
            File(assets, "image.png").writeBytes(byteArrayOf(1, 2, 3))
            val resolved = MediaPreviewPaths.resolve(
                root.path, "Workbench/Assets/image.png")
            assertNotNull(resolved)
            assertTrue(File(requireNotNull(resolved)).isFile)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun refusesAbsoluteAndEscapingPaths() {
        val root = Files.createTempDirectory("floe-workbench").toFile()
        try {
            assertNull(MediaPreviewPaths.resolve(root.path, "/etc/passwd"))
            assertNull(MediaPreviewPaths.resolve(root.path, "../outside.png"))
            assertNull(MediaPreviewPaths.resolve(root.path, "Workbench/../../outside.png"))
            assertNull(MediaPreviewPaths.resolve(root.path, ""))
            assertNull(MediaPreviewPaths.resolve(root.path, null))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun emptyRootNeverResolves() {
        assertNull(MediaPreviewPaths.resolve("", "Workbench/Assets/image.png"))
    }
}
