// SPDX-License-Identifier: MPL-2.0
//
// Thin seam over the existing C03 native audio chunker.
//
// The production implementation decodes the already-resolved app-owned source
// one bounded PCM16 WAV chunk at a time. JVM tests replace it with a fake that
// reports real chunk offsets without an Android codec.
package com.floe.android.host.meetingtranscription

import com.floe.android.host.voice.C03AudioChunk
import com.floe.android.host.voice.C03AudioChunker

internal interface MeetingAudioExtractor {
    suspend fun extract(
        sourcePath: String,
        stagingPath: String,
        chunkLimitBytes: Long,
        onChunk: suspend (C03AudioChunk) -> Unit,
    )

    fun cancel()
}

internal class AndroidMeetingAudioExtractor : MeetingAudioExtractor {
    private val chunker = C03AudioChunker()

    override suspend fun extract(
        sourcePath: String,
        stagingPath: String,
        chunkLimitBytes: Long,
        onChunk: suspend (C03AudioChunk) -> Unit,
    ) {
        chunker.extract(
            sourcePath = sourcePath,
            stagingPath = stagingPath,
            chunkLimitBytes = chunkLimitBytes,
            onChunk = onChunk,
        )
    }

    override fun cancel() {
        chunker.cancel()
    }
}
