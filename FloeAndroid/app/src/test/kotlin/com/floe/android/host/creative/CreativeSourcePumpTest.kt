// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import java.io.ByteArrayInputStream
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CreativeSourcePumpTest {
    private fun directory(): File {
        val value = File(
            System.getProperty("java.io.tmpdir"),
            "floe-pump-${java.util.UUID.randomUUID()}")
        value.mkdirs()
        return value
    }

    @Test
    fun `complete stream is fsynced renamed and hashed`() = runBlocking {
        val directory = directory()
        try {
            val bytes = ByteArray(4096) { (it % 251).toByte() }
            val target = File(directory, "staged.bin")
            val result = CreativeSourcePump().stage(
                ByteArrayInputStream(bytes), target, 8192)
            assertEquals(4096L, result.byteCount)
            assertEquals(64, result.sha256.length)
            assertTrue(target.isFile)
            assertFalse(directory.listFiles().orEmpty().any { it.name.endsWith(".part") })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `oversize stream fails without a committed target`() = runBlocking {
        val directory = directory()
        try {
            val target = File(directory, "staged.bin")
            val error = runCatching {
                CreativeSourcePump().stage(
                    ByteArrayInputStream(ByteArray(2048)), target, 1024)
            }.exceptionOrNull()
            assertTrue(error is CreativeException)
            assertEquals("assetTooLarge", (error as CreativeException).code)
            assertFalse(target.exists())
            assertFalse(directory.listFiles().orEmpty().any { it.name.endsWith(".part") })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `cancellation before commit deletes the partial file`() = runBlocking {
        val directory = directory()
        try {
            val target = File(directory, "staged.bin")
            val error = runCatching {
                CreativeSourcePump().stage(
                    ByteArrayInputStream(ByteArray(2048)), target, 4096,
                    isCancelled = { true })
            }.exceptionOrNull()
            assertTrue(error is CancellationException)
            assertFalse(target.exists())
            assertFalse(directory.listFiles().orEmpty().any { it.name.endsWith(".part") })
        } finally {
            directory.deleteRecursively()
        }
    }
}
