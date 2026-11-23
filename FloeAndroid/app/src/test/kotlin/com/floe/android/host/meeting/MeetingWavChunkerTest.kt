// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import com.floe.android.host.voice.C03AudioChunk
import com.floe.android.host.voice.C03AudioChunker
import com.floe.android.host.voice.C03Wav
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MeetingWavChunkerTest {
    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun `raw pcm wav chunks keep absolute offsets without a platform decoder`() = runBlocking {
        val source = File(folder.root, "live.wav")
        val frames = 60 * 16_000
        val data = ByteArray(frames * 2)
        var offset = 0
        repeat(frames) {
            data[offset] = 0x10.toByte()
            data[offset + 1] = 0x00.toByte()
            offset += 2
        }
        source.writeBytes(C03Wav.header(16_000, channels = 1, dataBytes = data.size) + data)
        val staging = folder.newFolder("staging")
        val chunks = ArrayList<C03AudioChunk>()

        C03AudioChunker().extract(
            sourcePath = source.absolutePath,
            stagingPath = staging.absolutePath,
            chunkLimitBytes = 1L * 1024L * 1024L,
        ) { chunk ->
            chunks += chunk
        }

        assertEquals(2, chunks.size)
        assertEquals(listOf(0, 1), chunks.map { it.index })
        assertEquals(0.0, chunks[0].sourceStartSeconds, 0.001)
        assertTrue(chunks[1].sourceStartSeconds > 0.0)
        assertTrue(chunks[0].durationSeconds > 0.0)
        assertEquals(
            60.0,
            chunks.sumOf { it.durationSeconds },
            0.05,
        )
        assertTrue(
            chunks[1].sourceStartSeconds + chunks[1].durationSeconds <= 60.001,
        )
    }
}
